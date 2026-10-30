import Foundation

enum Route: String, Sendable, CaseIterable {
    case eventsTrack = "events/track"
    case partial = "events/track_partial"
    case identify = "users/identify"
    case signals = "signals/track"
    case traces = "traces"
}

/// How queued items are framed into one request body.
struct Framing: Sendable {
    let prefix: Data
    let suffix: Data

    static let array = Framing(prefix: Data("[".utf8), suffix: Data("]".utf8))

    /// OTLP/HTTP JSON export request with one resource and one scope.
    static let otlp: Framing = {
        let resource: JSONValue = ["attributes": [
            ["key": "service.name", "value": ["stringValue": .string(RaindropSDK.serviceName)]],
            ["key": "service.version", "value": ["stringValue": .string(RaindropSDK.version)]],
        ]]
        let scope: JSONValue = ["name": .string(RaindropSDK.serviceName), "version": .string(RaindropSDK.version)]
        let head = "{\"resourceSpans\":[{\"resource\":" + String(decoding: JSONWriter.data(resource), as: UTF8.self)
            + ",\"scopeSpans\":[{\"scope\":" + String(decoding: JSONWriter.data(scope), as: UTF8.self) + ",\"spans\":["
        return Framing(prefix: Data(head.utf8), suffix: Data("]}]}]}".utf8))
    }()
}

/// Latest-wins store for partial (begin/patch/finish) snapshots, keyed by event id.
/// Each snapshot carries the interaction's full accumulated state, so a newer one
/// supersedes an older one, including an older one parked for retry.
struct PartialEntry: Sendable {
    var snapshot: JSONValue?   // not yet serialized
    var batch: Batch?          // serialized (in flight or parked)
    var version: Int
}

/// A serialized request body. Built once and resent byte-for-byte on every retry, so
/// retries carry identical bodies and stable event ids.
struct Batch: Sendable {
    let route: Route
    let body: Data
    let count: Int
    var failedCycles = 0
    var createdAt = Date()
    var mirrored = false
}

/// Queue + delivery engine for one client.
///
/// Execution model (shared with the other Raindrop SDKs):
/// - `enqueue` is the only thing hot-path calls do: append under a lock, no I/O,
///   no sleeps, no serialization.
/// - Delivery runs in background tasks. Drains are serialized: at most one is in flight,
///   so a batch is never sent twice concurrently.
/// - `flush` / `close` drains are bounded by a deadline. They may wait out a
///   capped `Retry-After` or backoff inside that deadline; background drains never wait.
///   They park the batch and set a not-before time for the route instead.
/// - 2xx = delivered regardless of body (`rejected` / `warnings` in it are logged); 408, 429
///   and 5xx are retried; any other 4xx is dropped, never retried.
final class Pipeline: @unchecked Sendable {
    enum Mode { case background, lifecycle }

    private enum Outcome {
        case delivered
        case dropped
        case park(after: Duration)
    }

    private let config: RaindropConfiguration
    private let transport: any HTTPTransport
    private let log: Log
    private let headers: [String: String]
    private let storage: Storage?
    private let workshopURL: URL?
    /// False in Workshop-only mode (no write key): payloads go to the local mirror only.
    private let cloudEnabled: Bool

    private let lock = NSLock()
    private var queues: [Route: [JSONValue]] = [:]
    private var partials: [String: PartialEntry] = [:]
    private var partialOrder: [String] = []
    private var partialVersion = 0
    private var parked: [Route: [Batch]] = [:]
    private var notBefore: [Route: ContinuousClock.Instant] = [:]
    private var chain: Task<FlushResult, Never>?
    private var backgroundBusy = false
    private var closed = false
    private var timer: Task<Void, Never>?

    private static let maxParkedBatches = 100
    private static let maxFailedCycles = 20

    init(config: RaindropConfiguration, log: Log, storage: Storage?, workshopURL: URL?) {
        self.config = config
        self.log = log
        self.storage = storage
        self.workshopURL = workshopURL
        self.cloudEnabled = config.isEnabled
        self.transport = config.transport ?? URLSessionTransport()
        var h = [
            "Authorization": "Bearer \(config.writeKey ?? "")",
            "Content-Type": "application/json",
            "User-Agent": "\(RaindropSDK.libraryName)/\(RaindropSDK.version)",
        ]
        if let project = config.projectHeader { h["X-Raindrop-Project-Id"] = project }
        self.headers = h
    }

    deinit { timer?.cancel() }

    // MARK: Hot path

    /// Appends one payload. Returns false when the client is closed.
    @discardableResult
    func enqueue(_ route: Route, _ item: JSONValue) -> Bool {
        let overflow: Int = lock.withLock {
            if closed { return -1 }
            queues[route, default: []].append(item)
            let excess = queues[route]!.count - config.maxQueueSize
            if excess > 0 { queues[route]!.removeFirst(excess) }
            return max(0, excess)
        }
        if overflow < 0 {
            log.warn("closed", "client is closed; dropping \(route.rawValue) payload")
            return false
        }
        if overflow > 0 {
            log.warn("overflow.\(route.rawValue)", "queue full (\(config.maxQueueSize)); dropped oldest \(route.rawValue) payload(s)")
        }
        return true
    }

    /// Stores the latest snapshot of a partial event. Replaces any unsent or parked one.
    @discardableResult
    func enqueuePartial(eventId: String, _ snapshot: JSONValue) -> Bool {
        let accepted: Bool = lock.withLock {
            if closed { return false }
            partialVersion += 1
            if partials[eventId] == nil { partialOrder.append(eventId) }
            partials[eventId] = PartialEntry(snapshot: snapshot, batch: nil, version: partialVersion)
            if partialOrder.count > config.maxQueueSize, let oldest = partialOrder.first {
                partialOrder.removeFirst()
                partials[oldest] = nil
            }
            return true
        }
        if !accepted { log.warn("closed", "client is closed; dropping interaction update") }
        return accepted
    }

    // MARK: Lifecycle

    func startBackgroundLoop() {
        let interval = config.flushInterval
        let task = Task.detached(priority: .utility) { [weak self] in
            _ = self?.ensureRestored()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.backgroundTick()
            }
        }
        lock.withLock { timer = task }
    }

    func flush() async -> FlushResult {
        await serialDrain(mode: .lifecycle, deadline: .now + config.flushDeadline)
    }

    func flush(within budget: Duration) async -> FlushResult {
        await serialDrain(mode: .lifecycle, deadline: .now + min(budget, config.flushDeadline))
    }

    func close() async -> FlushResult {
        let alreadyClosed: Bool = lock.withLock {
            let was = closed
            closed = true
            timer?.cancel()
            timer = nil
            return was
        }
        if alreadyClosed { return FlushResult(pending: pendingCount()) }
        let result = await serialDrain(mode: .lifecycle, deadline: .now + config.flushDeadline)
        if !result.isComplete { await checkpoint() }   // keep what didn't make it for the next run
        return result
    }

    func pendingCount() -> Int {
        lock.withLock {
            queues.values.reduce(0) { $0 + $1.count } + parked.values.joined().reduce(0) { $0 + $1.count } + partials.count
        }
    }

    private func backgroundTick() async {
        ensureRestored()
        let start: Bool = lock.withLock {
            guard !backgroundBusy, !closed else { return false }
            let hasWork = queues.values.contains { !$0.isEmpty } || parked.values.contains { !$0.isEmpty } || !partials.isEmpty
            if hasWork { backgroundBusy = true }
            return hasWork
        }
        guard start else { return }
        _ = await serialDrain(mode: .background, deadline: nil)
        lock.withLock { backgroundBusy = false }
    }

    /// Runs a drain after any in-flight one. A lifecycle caller stops waiting at its
    /// deadline even if an earlier drain is still running.
    private func serialDrain(mode: Mode, deadline: ContinuousClock.Instant?) async -> FlushResult {
        let task: Task<FlushResult, Never> = lock.withLock {
            let previous = chain
            let next = Task.detached(priority: .utility) { [self] in
                _ = await previous?.value
                return await self.drainNow(mode: mode, deadline: deadline)
            }
            chain = next
            return next
        }
        guard let deadline else { return await task.value }
        if let result = await Self.value(of: task, before: deadline) { return result }
        return FlushResult(pending: pendingCount(), timedOut: true)
    }

    // MARK: Offline storage

    private let restoreLock = NSLock()
    private var restorePending = true

    /// Puts payloads saved by a previous run back in line (as parked, serialized batches).
    /// Retried until the file can be read (data protection can make it unreadable while the
    /// device is locked). Returns false while saved data is still waiting to be read.
    @discardableResult
    func ensureRestored() -> Bool {
        guard let storage else { return true }
        return restoreLock.withLock {
            guard restorePending else { return true }
            guard let records = storage.takeAll() else { return false }
            restorePending = false
            restore(records)
            return true
        }
    }

    private func restore(_ records: [Storage.Record]) {
        guard !records.isEmpty else { return }
        lock.withLock {
            for r in records {
                if r.route == .partial {
                    guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                          let id = obj["event_id"] as? String, partials[id] == nil else { continue }
                    partialVersion += 1
                    partialOrder.append(id)
                    partials[id] = PartialEntry(snapshot: nil, batch: Batch(route: .partial, body: r.body, count: 1, createdAt: r.savedAt), version: partialVersion)
                } else {
                    let count = r.route == .traces ? 1 : ((try? JSONSerialization.jsonObject(with: r.body) as? [Any])?.count ?? 1)
                    parked[r.route, default: []].append(Batch(route: r.route, body: r.body, count: count, createdAt: r.savedAt))
                }
            }
        }
        log.debug("restored \(records.count) unsent payload batch(es) from disk")
    }

    /// Writes every serialized-but-unsent payload to disk (or clears the file when none).
    private func syncStorage() {
        guard let storage else { return }
        // Never overwrite a previous run's file before it has been read back.
        guard ensureRestored() else {
            log.debug("offline storage from a previous run not readable yet; not saving over it")
            return
        }
        let records: [Storage.Record] = lock.withLock {
            var out: [Storage.Record] = []
            for route in Route.allCases {
                for b in parked[route] ?? [] { out.append(.init(route: route, body: b.body, savedAt: b.createdAt)) }
            }
            for id in partialOrder {
                if let b = partials[id]?.batch { out.append(.init(route: .partial, body: b.body, savedAt: b.createdAt)) }
            }
            return out.sorted { $0.savedAt < $1.savedAt }
        }
        storage.write(records)
    }

    /// Serializes everything still queued in memory and saves it, so nothing is lost if
    /// the process is suspended and killed. Runs after any in-flight drain.
    func checkpoint() async {
        guard storage != nil else { return }
        let task: Task<FlushResult, Never> = lock.withLock {
            let previous = chain
            let next = Task.detached(priority: .utility) { [self] in
                _ = await previous?.value
                var dropped = 0
                for route in [Route.eventsTrack, .identify, .signals, .traces] {
                    // Queued items only: parked batches are already serialized.
                    while let batch = nextBatch(route, dropped: &dropped, includeParked: false) {
                        lock.withLock { parked[route, default: []].append(batch) }
                    }
                }
                // beforeSend is user code: never call it while holding the lock.
                let pending: [(String, Int, JSONValue)] = lock.withLock {
                    partialOrder.compactMap { id in
                        guard let e = partials[id], e.batch == nil, let snap = e.snapshot else { return nil }
                        return (id, e.version, snap)
                    }
                }
                for (id, version, snap) in pending {
                    guard let prepared = prepare(.partial, snap) else { continue }
                    let batch = Batch(route: .partial, body: JSONWriter.data(prepared), count: 1)
                    lock.withLock {
                        if partials[id]?.version == version {
                            partials[id]?.batch = batch
                            partials[id]?.snapshot = nil
                        }
                    }
                }
                syncStorage()
                return FlushResult()
            }
            chain = next
            return next
        }
        _ = await task.value
    }

    /// Network came back: retry parked payloads now instead of waiting out backoff.
    func wake() {
        lock.withLock { notBefore.removeAll() }
        Task.detached(priority: .utility) { [weak self] in await self?.backgroundTick() }
    }

    // MARK: Drain

    private func drainNow(mode: Mode, deadline: ContinuousClock.Instant?) async -> FlushResult {
        var result = FlushResult()
        // Events before signals and spans: both reference an event id.
        routes: for route in [Route.eventsTrack, .partial, .identify, .signals, .traces] {
            while true {
                if let wait = lock.withLock({ notBefore[route] }), wait > .now {
                    guard mode == .lifecycle, let deadline, wait < deadline else {
                        if mode == .lifecycle { result.timedOut = true }
                        continue routes
                    }
                    try? await Task.sleep(until: wait, clock: .continuous)
                }
                if let deadline, ContinuousClock.now >= deadline {
                    result.timedOut = true
                    break routes
                }
                if route == .partial {
                    guard let (eventId, version, batch) = nextPartial(dropped: &result.dropped) else { continue routes }
                    var b = batch
                    let outcome = await deliver(&b, mode: mode, deadline: deadline)
                    if case .park(let after) = outcome {
                        parkPartial(eventId, version: version, batch: b, after: after, dropped: &result.dropped)
                        if mode == .lifecycle, let deadline, ContinuousClock.now >= deadline { result.timedOut = true }
                        continue routes
                    }
                    completePartial(eventId, version: version)
                    if case .delivered = outcome {
                        result.delivered += 1
                        lock.withLock { notBefore[route] = nil }
                    } else {
                        result.dropped += 1
                    }
                    continue
                }
                guard var batch = nextBatch(route, dropped: &result.dropped) else { continue routes }
                switch await deliver(&batch, mode: mode, deadline: deadline) {
                case .delivered:
                    result.delivered += batch.count
                    lock.withLock { notBefore[route] = nil }
                case .dropped:
                    result.dropped += batch.count
                case .park(let after):
                    park(batch, after: after, dropped: &result.dropped)
                    if mode == .lifecycle, let deadline, ContinuousClock.now >= deadline { result.timedOut = true }
                    continue routes
                }
            }
        }
        result.pending = pendingCount()
        syncStorage()
        return result
    }

    /// Parked batches first (oldest data), otherwise a new batch from the queue.
    private func nextBatch(_ route: Route, dropped: inout Int, includeParked: Bool = true) -> Batch? {
        if includeParked, let parkedBatch: Batch = lock.withLock({ parked[route]?.isEmpty == false ? parked[route]!.removeFirst() : nil }) {
            return parkedBatch
        }
        while true {
            let items: [JSONValue] = lock.withLock {
                let all = queues[route] ?? []
                let take = Array(all.prefix(config.maxBatchSize))
                queues[route] = Array(all.dropFirst(take.count))
                return take
            }
            if items.isEmpty { return nil }

            var parts: [Data] = []
            var bytes = route == .traces ? Framing.otlp.prefix.count + Framing.otlp.suffix.count : 2
            var used = 0
            for item in items {
                guard let prepared = prepare(route, item) else {
                    dropped += 1
                    used += 1
                    continue
                }
                let data = JSONWriter.data(prepared)
                if !parts.isEmpty, bytes + data.count + 1 > config.maxBatchBytes { break }
                parts.append(data)
                bytes += data.count + 1
                used += 1
            }
            if used < items.count {
                let rest = Array(items.dropFirst(used))
                lock.withLock { queues[route] = rest + (queues[route] ?? []) }
            }
            if parts.isEmpty { continue } // everything in this slice was dropped by beforeSend

            let framing = route == .traces ? Framing.otlp : Framing.array
            var body = framing.prefix
            for (i, part) in parts.enumerated() {
                if i > 0 { body.append(UInt8(ascii: ",")) }
                body.append(part)
            }
            body.append(framing.suffix)
            return Batch(route: route, body: body, count: parts.count)
        }
    }

    /// Truncation and `beforeSend`, applied off the hot path just before serialization.
    private func prepare(_ route: Route, _ item: JSONValue) -> JSONValue? {
        guard var object = item.objectValue else { return item }
        if route == .eventsTrack || route == .partial, var ai = object["ai_data"]?.objectValue {
            for key in ["input", "output"] {
                if var text = ai[key]?.stringValue {
                    if config.redactPii { text = PIIRedactor.redact(text) }
                    ai[key] = .string(Truncation.truncate(text, limit: config.maxTextFieldChars))
                }
            }
            object["ai_data"] = .object(ai)
        }
        if route == .traces, config.redactPii {
            PIIRedactor.redactSpan(&object, limit: config.maxTextFieldChars)
        }
        if let hook = config.beforeSend {
            guard let edited = hook(RaindropPayload(route: route.rawValue, body: object)) else { return nil }
            object = edited.body
        }
        return .object(object)
    }

    /// Next partial to send: its parked bytes if unchanged, else a freshly serialized snapshot.
    /// Rotates the order so one stuck event can't starve the others.
    private func nextPartial(dropped: inout Int) -> (String, Int, Batch)? {
        var remaining = lock.withLock { partialOrder.count }
        while remaining > 0 {
            remaining -= 1
            let picked: (String, PartialEntry)? = lock.withLock {
                while let id = partialOrder.first {
                    partialOrder.removeFirst()
                    if let entry = partials[id] {
                        partialOrder.append(id)
                        return (id, entry)
                    }
                }
                return nil
            }
            guard let (id, entry) = picked else { return nil }
            if let batch = entry.batch { return (id, entry.version, batch) }
            guard let snapshot = entry.snapshot, let prepared = prepare(.partial, snapshot) else {
                dropped += 1
                completePartial(id, version: entry.version)
                continue
            }
            let batch = Batch(route: .partial, body: JSONWriter.data(prepared), count: 1)
            lock.withLock {
                if partials[id]?.version == entry.version {
                    partials[id]?.batch = batch
                    partials[id]?.snapshot = nil
                }
            }
            return (id, entry.version, batch)
        }
        return nil
    }

    /// Removes a sent (or permanently rejected) partial, unless a newer snapshot arrived meanwhile.
    private func completePartial(_ id: String, version: Int) {
        lock.withLock {
            guard partials[id]?.version == version else { return }
            partials[id] = nil
            partialOrder.removeAll { $0 == id }
        }
    }

    private func parkPartial(_ id: String, version: Int, batch: Batch, after: Duration, dropped: inout Int) {
        var batch = batch
        batch.failedCycles += 1
        if batch.failedCycles >= Self.maxFailedCycles {
            dropped += 1
            completePartial(id, version: version)
            log.warn("giveup.partial", "giving up on an interaction update after \(batch.failedCycles) failed send cycles")
            return
        }
        lock.withLock {
            if partials[id]?.version == version { partials[id]?.batch = batch }
            notBefore[.partial] = .now + after
        }
    }

    private func park(_ batch: Batch, after: Duration, dropped: inout Int) {
        var batch = batch
        batch.failedCycles += 1
        if batch.failedCycles >= Self.maxFailedCycles {
            dropped += batch.count
            log.warn("giveup.\(batch.route.rawValue)", "giving up on \(batch.count) \(batch.route.rawValue) payload(s) after \(batch.failedCycles) failed send cycles")
            return
        }
        let evicted: Int = lock.withLock {
            parked[batch.route, default: []].insert(batch, at: 0)
            notBefore[batch.route] = .now + after
            var evicted = 0
            while parked[batch.route]!.count > Self.maxParkedBatches {
                evicted += parked[batch.route]!.removeLast().count
            }
            return evicted
        }
        if evicted > 0 {
            dropped += evicted
            log.warn("parked.\(batch.route.rawValue)", "retry buffer full; dropped \(evicted) oldest \(batch.route.rawValue) payload(s)")
        }
    }

    // MARK: Delivery

    private func deliver(_ batch: inout Batch, mode: Mode, deadline: ContinuousClock.Instant?) async -> Outcome {
        if let workshopURL, !batch.mirrored {
            batch.mirrored = true
            let request = HTTPRequest(url: workshopURL.appendingPathComponent(batch.route.rawValue), headers: headers,
                                      body: batch.body, timeout: .seconds(2))
            let transport = self.transport
            let mirror = Task.detached { _ = try? await transport.send(request) }   // best effort, one attempt
            if !cloudEnabled {
                await mirror.value
                return .delivered
            }
        }
        let url = config.endpoint.appendingPathComponent(batch.route.rawValue)
        var attempts = 0
        var reconnects = 0
        while true {
            var timeout = config.requestTimeout
            if let deadline {
                let remaining = deadline - .now
                if remaining <= .zero { return .park(after: .zero) }
                timeout = min(timeout, remaining)
            }
            attempts += 1
            do {
                let response = try await transport.send(HTTPRequest(url: url, headers: headers, body: batch.body, timeout: timeout))
                switch response.status {
                case 200..<300:
                    log.debug("delivered \(batch.count) \(batch.route.rawValue) payload(s)")
                    reportIngestResponse(response.body, route: batch.route)
                    return .delivered
                case 408, 429, 500...599:
                    let delay = retryDelay(response, attempt: attempts)
                    log.debug("HTTP \(response.status) on \(batch.route.rawValue); retry in \(delay)")
                    guard mode == .lifecycle, attempts < config.maxAttempts, let deadline,
                          ContinuousClock.now + delay < deadline else {
                        if attempts >= config.maxAttempts {
                            log.warn("retry.\(batch.route.rawValue)", "HTTP \(response.status) from \(batch.route.rawValue) after \(attempts) attempts; will retry later")
                        }
                        return .park(after: delay)
                    }
                    try? await Task.sleep(for: delay)
                default:
                    log.warn("reject.\(batch.route.rawValue).\(response.status)",
                             "dropping \(batch.count) \(batch.route.rawValue) payload(s): HTTP \(response.status) \(String(decoding: response.body.prefix(300), as: UTF8.self))")
                    return .dropped
                }
            } catch TransportError.connectionLost where reconnects < 3 {
                // Accepted-then-closed or reset: resend the identical body right away.
                reconnects += 1
                attempts -= 1
            } catch TransportError.timedOut {
                log.warn("timeout.\(batch.route.rawValue)", "request to \(batch.route.rawValue) timed out; will retry later")
                return .park(after: .zero)
            } catch {
                log.warn("transport.\(batch.route.rawValue)", "request to \(batch.route.rawValue) failed (\(error)); will retry later")
                return .park(after: backoff(attempt: attempts))
            }
        }
    }

    /// A 2xx is delivered whatever its body says. Ingest lists items it did not store under
    /// `rejected` and input it accepted with changes (such as ignored fields) under `warnings`;
    /// both are warnings. An empty, non-JSON or unexpected body is ignored.
    private func reportIngestResponse(_ body: Data, route: Route) {
        guard !body.isEmpty, let object = try? JSONDecoder().decode(JSONValue.self, from: body).objectValue else { return }
        if case .array(let rejected)? = object["rejected"], !rejected.isEmpty {
            let quoted = rejected.prefix(3).map { item -> String in
                let o = item.objectValue ?? [:]
                let issues: [String]
                if case .array(let list)? = o["issues"] {
                    issues = list.compactMap { issue in
                        guard let i = issue.objectValue else { return nil }
                        let message = i["message"]?.stringValue ?? "invalid"
                        if let path = i["path"]?.stringValue, !path.isEmpty { return "\(path): \(message)" }
                        return message
                    }
                } else {
                    issues = []
                }
                return "\(Self.itemLabel(o)) (\(issues.isEmpty ? "invalid" : issues.joined(separator: "; ")))"
            }
            let more = rejected.count > 3 ? " (+\(rejected.count - 3) more)" : ""
            log.warn("ingest.rejected.\(route.rawValue)",
                     "\(route.rawValue): ingest rejected \(rejected.count) item(s), which were not stored: "
                        + quoted.joined(separator: " | ") + more)
        }
        if case .array(let warnings)? = object["warnings"], !warnings.isEmpty {
            let quoted = warnings.prefix(3).map { item -> String in
                let o = item.objectValue ?? [:]
                if let message = o["message"]?.stringValue, !message.isEmpty { return "\(Self.itemLabel(o)): \(message)" }
                var fields: [String] = []
                if case .array(let list)? = o["fields"] { fields = list.compactMap(\.stringValue) }
                return "\(Self.itemLabel(o)): ignored \(fields.isEmpty ? "input" : fields.joined(separator: ", "))"
            }
            let more = warnings.count > 3 ? " (+\(warnings.count - 3) more)" : ""
            log.warn("ingest.warnings.\(route.rawValue)",
                     "\(route.rawValue): ingest accepted \(warnings.count) item(s) with changes: "
                        + quoted.joined(separator: " | ") + more)
        }
    }

    private static func itemLabel(_ item: [String: JSONValue]) -> String {
        if let id = item["event_id"]?.stringValue, !id.isEmpty { return "event \(id)" }
        if case .int(let i)? = item["index"] { return "item \(i)" }
        return "item"
    }

    private func retryDelay(_ response: HTTPResponse, attempt: Int) -> Duration {
        if let header = response.headers["retry-after"], let seconds = Self.parseRetryAfter(header) {
            return min(.milliseconds(Int64(seconds * 1000)), config.maxRetryAfter)
        }
        return backoff(attempt: attempt)
    }

    /// 0.5 s, 1 s, 2 s … capped at 8 s, with ±20 % jitter so many clients don't retry in lockstep.
    private func backoff(attempt: Int) -> Duration {
        let base = min(8.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        let jittered = base * Double.random(in: 0.8...1.2)
        return .milliseconds(Int64(jittered * 1000))
    }

    /// `Retry-After` is either delta-seconds or an HTTP-date.
    static func parseRetryAfter(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    // MARK: Helpers

    /// Waits for `task` but gives up at `deadline`, leaving the task running.
    static func value<T: Sendable>(of task: Task<T, Never>, before deadline: ContinuousClock.Instant) async -> T? {
        let gate = ResumeOnce<T?>()
        return await withCheckedContinuation { continuation in
            gate.set(continuation)
            let timer = Task.detached {
                try? await Task.sleep(until: deadline, clock: .continuous)
                gate.resume(nil)
            }
            Task.detached {
                let value = await task.value
                timer.cancel()
                gate.resume(value)
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever side gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: [T] = []   // a value that arrived before `set` (at most one)
    private var finished = false

    func set(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if let value = early.first {
            lock.unlock()
            c.resume(returning: value)
            return
        }
        continuation = c
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: value)
        } else {
            early = [value]
            lock.unlock()
        }
    }
}
