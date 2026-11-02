import Foundation

/// Opens an interaction with `RaindropClient.begin(_:)`.
public struct BeginOptions: Sendable {
    public var userId: String
    public var event: String
    public var input: String?
    public var model: String?
    public var convoId: String?
    /// Your own event id. When nil the SDK generates a UUID.
    public var eventId: String?
    /// Event time. Defaults to now and is kept through `finish` (the event's time is its begin time).
    public var timestamp: Date?
    public var properties: [String: JSONValue]
    public var attachments: [Attachment]
    public var featureFlags: [String: String]

    public init(userId: String, event: String, input: String? = nil, model: String? = nil, convoId: String? = nil,
                eventId: String? = nil, timestamp: Date? = nil, properties: [String: JSONValue] = [:],
                attachments: [Attachment] = [], featureFlags: [String: String] = [:]) {
        self.userId = userId
        self.event = event
        self.input = input
        self.model = model
        self.convoId = convoId
        self.eventId = eventId
        self.timestamp = timestamp
        self.properties = properties
        self.attachments = attachments
        self.featureFlags = featureFlags
    }
}

/// A partial change to an open interaction. Nil fields are left unchanged; `properties`
/// merge and `attachments` append.
public struct InteractionUpdate: Sendable {
    public var userId: String?
    public var event: String?
    public var input: String?
    public var output: String?
    public var model: String?
    public var convoId: String?
    public var timestamp: Date?
    public var properties: [String: JSONValue]
    public var attachments: [Attachment]

    public init(userId: String? = nil, event: String? = nil, input: String? = nil, output: String? = nil,
                model: String? = nil, convoId: String? = nil, timestamp: Date? = nil,
                properties: [String: JSONValue] = [:], attachments: [Attachment] = []) {
        self.userId = userId
        self.event = event
        self.input = input
        self.output = output
        self.model = model
        self.convoId = convoId
        self.timestamp = timestamp
        self.properties = properties
        self.attachments = attachments
    }
}

/// A long-running AI interaction delivered through `POST /v1/events/track_partial`:
/// `begin` → updates → `finish`.
///
/// Each send carries the interaction's full accumulated state, so the backend can merge
/// by event id even if an earlier send was lost. Updates only queue (hot path); `finish`
/// sends and returns within `flushDeadline`.
///
/// Pending updates wait until the interaction has input or output; `finish` sends either way.
/// An interaction without a `userId` is not sent until an update sets one (a resumed one is).
///
/// To finish in another process, keep `eventId` (and the begin time) and call
/// `RaindropClient.resumeInteraction(eventId:beganAt:)` there.
public final class Interaction: @unchecked Sendable {
    public let eventId: String

    private let pipeline: Pipeline?
    private let log: Log
    private let context: JSONValue
    private let appGit: AppGitSnapshot
    private let spanContext: SpanContext
    private let onFinish: @Sendable (String) -> Void

    private let lock = NSLock()
    private var userId: String?
    private var event: String?
    private var input: String?
    private var output: String?
    private var model: String?
    private var convoId: String?
    private var timestamp: Date?
    private var properties: [String: JSONValue] = [:]
    private var attachments: [Attachment] = []
    private var featureFlags: [String: String] = [:]
    private var finished = false
    /// Continued by id (`resumeInteraction`): its user, start and content may live in another process.
    private var resumed = false
    /// Reverse link stamped on every span when this interaction is a detached subagent.
    private var subagentLink: [String: JSONValue] = [:]
    /// Set once this turn dispatches a subagent (see `subagent(name:)`).
    private var toolEventsAllowed = false
    private let errorFlag = ErrorFlag()

    init(eventId: String, pipeline: Pipeline?, log: Log, context: JSONValue, appGit: AppGitSnapshot,
         spanContext: SpanContext, onFinish: @escaping @Sendable (String) -> Void) {
        self.eventId = eventId
        self.pipeline = pipeline
        self.log = log
        self.context = context
        self.appGit = appGit
        self.spanContext = spanContext
        self.onFinish = onFinish
    }

    func seed(_ o: BeginOptions) {
        lock.withLock {
            userId = o.userId
            event = o.event
            input = o.input
            model = o.model
            convoId = o.convoId
            timestamp = o.timestamp ?? Date()
            properties = o.properties
            attachments = o.attachments
            featureFlags = o.featureFlags
        }
        publish(final: false)
    }

    func markSubagent(_ link: [String: JSONValue]) {
        lock.withLock { subagentLink = link }
    }

    func seedResumed(beganAt: Date?) {
        lock.withLock {
            timestamp = beganAt
            resumed = true
        }
    }

    // MARK: Updates (hot path: queue only)

    public func update(_ u: InteractionUpdate) {
        let ok: Bool = lock.withLock {
            guard !finished else { return false }
            if let v = u.userId { userId = v }
            if let v = u.event { event = v }
            if let v = u.input { input = v }
            if let v = u.output { output = v }
            if let v = u.model { model = v }
            if let v = u.convoId { convoId = v }
            if let v = u.timestamp { timestamp = v }
            properties.merge(u.properties) { _, new in new }
            attachments.append(contentsOf: u.attachments)
            return true
        }
        guard ok else {
            log.warn("finished.\(eventId)", "interaction \(eventId) is finished; ignoring update")
            return
        }
        publish(final: false)
    }

    public func setInput(_ input: String) { update(InteractionUpdate(input: input)) }
    public func setProperty(_ key: String, _ value: JSONValue) { update(InteractionUpdate(properties: [key: value])) }
    public func setProperties(_ values: [String: JSONValue]) { update(InteractionUpdate(properties: values)) }
    public func addAttachments(_ items: [Attachment]) { update(InteractionUpdate(attachments: items)) }

    // MARK: Finish (bounded, durable on return)

    /// Records the final output and sends the completed event. Returns once delivered or
    /// at `flushDeadline`. Calling it twice is a no-op.
    @discardableResult
    public func finish(output: String? = nil, model: String? = nil, properties: [String: JSONValue] = [:],
                       attachments: [Attachment] = [], timestamp: Date? = nil) async -> FlushResult {
        let ok: Bool = lock.withLock {
            guard !finished else { return false }
            if let output { self.output = output }
            if let model { self.model = model }
            if let timestamp { self.timestamp = timestamp }
            self.properties.merge(properties) { _, new in new }
            self.attachments.append(contentsOf: attachments)
            finished = true
            return true
        }
        guard ok else { return FlushResult() }
        publish(final: true)
        onFinish(eventId)
        return await pipeline?.flush() ?? FlushResult()
    }

    /// Queues the accumulated state. Pending updates wait until there is input or output.
    private func publish(final: Bool) {
        guard let pipeline else { return }
        let (hasUser, wasResumed) = lock.withLock { (!(userId ?? "").isEmpty, resumed) }
        let (snapshot, hasContent): (JSONValue, Bool) = lock.withLock {
            var props = properties
            if props["$context"] == nil { props["$context"] = context }
            appGit.fill(&props)
            var body: [String: JSONValue] = [
                "event_id": .string(eventId),
                "is_pending": .bool(!final),
                "properties": .object(props),
            ]
            if let userId, !userId.isEmpty { body["user_id"] = .string(userId) }
            if let event, !event.isEmpty { body["event"] = .string(event) }
            if let timestamp { body["timestamp"] = .string(RaindropClient.iso8601(timestamp)) }
            if !attachments.isEmpty { body["attachments"] = .array(attachments.map(RaindropClient.encode)) }
            if !featureFlags.isEmpty { body["feature_flags"] = .object(featureFlags.mapValues { .string($0) }) }
            let hasContent = !(input ?? "").isEmpty || !(output ?? "").isEmpty
            if hasContent {
                var ai: [String: JSONValue] = [:]
                if let input { ai["input"] = .string(input) }
                if let output { ai["output"] = .string(output) }
                if let model { ai["model"] = .string(model) }
                if let convoId { ai["convo_id"] = .string(convoId) }
                body["ai_data"] = .object(ai)
            }
            return (.object(body), hasContent)
        }
        if !hasContent && !final { return }   // hold until there is content
        if !hasUser {
            // A begun event without a user is not sent (a later update can add one). A resumed
            // event is: Raindrop keeps the user it already has for that event id.
            guard wasResumed else {
                log.warn("no-user.\(eventId)", "interaction \(eventId) has no userId; not sending it until an update sets one")
                return
            }
            log.warn("resumed-no-user", "sending an update for resumed interaction \(eventId) without a userId; "
                + "Raindrop uses the user it already has for this event")
        }
        if !hasContent {
            // Still sent: whether an empty event is kept is Raindrop's call. A resumed event is
            // exempt because another process may have sent its content.
            if !wasResumed {
                log.warn("empty.\(eventId)", "interaction \(eventId) finished with no input or output; sending it anyway")
            }
        }
        pipeline.enqueuePartial(eventId: eventId, snapshot)
    }

    // MARK: Spans (linked to this interaction's event, user and conversation)

    private func context(for kind: String) -> SpanContext {
        var c = spanContext
        c.errorFlag = errorFlag
        let (u, cv, e, link, allow) = lock.withLock { (userId, convoId, event, subagentLink, toolEventsAllowed) }
        c.extraAttributes.merge(link) { _, new in new }
        if allow { c.extraAttributes[Handoff.toolEventsKey] = .string(Handoff.toolEventsAllow) }
        if let u { c.association["user_id"] = u }
        if let cv { c.association["convo_id"] = cv }
        if let e { c.association["event"] = e }
        return c
    }

    /// A generic span (workflow step, retrieval, …).
    public func startSpan(_ name: String, parent: SpanParent? = nil, operationId: String = "ai.task",
                          attributes: [String: JSONValue] = [:], startTime: Date? = nil) -> Span {
        let span = Span(name: name, parent: parent, start: startTime, context: context(for: "task"))
        span.setAttribute("ai.operationId", .string(operationId))
        span.setAttributes(attributes)
        return span
    }

    /// A model call.
    public func startLlmSpan(_ name: String, provider: String? = nil, model: String? = nil, input: String? = nil,
                             messages: [LlmMessage]? = nil, tools: [ToolDeclaration]? = nil,
                             parent: SpanParent? = nil, startTime: Date? = nil) -> LlmSpan {
        let llm = LlmSpan(span: Span(name: name, parent: parent, start: startTime, context: context(for: "llm")))
        if let provider { llm.setProvider(provider) }
        if let model { llm.setModel(model) }
        if let messages { llm.setMessages(messages) } else if let input { llm.setInput(input) }
        if let tools { llm.setTools(tools) }
        return llm
    }

    /// A tool execution you end yourself.
    public func startToolSpan(_ name: String, input: JSONValue? = nil, parent: SpanParent? = nil,
                              startTime: Date? = nil) -> ToolSpan {
        let tool = ToolSpan(span: Span(name: name, parent: parent, start: startTime, context: context(for: "tool")), name: name)
        if let input { tool.setInput(input) }
        return tool
    }

    /// Records a tool call that already happened: a start time plus a `duration` or an
    /// `endTime` (when both are given, `endTime` wins). Pass `parent: .ref(saved)` to place it
    /// under a span whose ids were saved, for example by another process.
    public func trackTool(_ name: String, input: JSONValue? = nil, output: JSONValue? = nil, error: String? = nil,
                          duration: Duration? = nil, startTime: Date? = nil, endTime: Date? = nil,
                          parent: SpanParent? = nil) {
        let given = duration ?? .zero
        var seconds = Double(given.components.seconds) + Double(given.components.attoseconds) / 1e18
        let start: Date
        if let endTime {
            start = startTime ?? endTime.addingTimeInterval(-seconds)
            seconds = max(0, endTime.timeIntervalSince(start))
        } else {
            start = startTime ?? Date().addingTimeInterval(-seconds)
        }
        let tool = ToolSpan(span: Span(name: name, parent: parent, start: start, context: context(for: "tool")), name: name)
        if let input { tool.setInput(input) }
        if let output { tool.setOutput(output) }
        if let error { tool.setError(error) }
        tool.span.setAttribute("traceloop.entity.duration_ms", .int(Int64((seconds * 1000).rounded(.down))))
        tool.span.end(at: start.addingTimeInterval(seconds))
    }

    // MARK: Detached subagents (raindrop.handoff.* contract)

    /// Records that this turn launched a detached subagent: work that reports as its OWN
    /// event (in another task, thread or process) linked back to this one.
    ///
    /// Records a `launch_subagent` tool span carrying `raindrop.handoff.mode=detached`, the
    /// child's event id and name, and returns a `SubagentHandoff` with the ids the child
    /// needs. Pass it to `RaindropClient.beginSubagent(_:userId:...)` wherever the work runs:
    /// a `Task.detached`, another thread, or (encoded with `Codable`) another process.
    ///
    /// Also opts this turn's later spans into tool-call-only event creation, so a turn
    /// whose only content is dispatches still becomes an event.
    @discardableResult
    public func subagent(name: String = "subagent", input: JSONValue? = nil, childEventId: String? = nil,
                         toolName: String = "launch_subagent") -> SubagentHandoff {
        let childId = (childEventId?.isEmpty == false ? childEventId! : UUID().uuidString.lowercased())
        let resolvedName = name.isEmpty ? "subagent" : name
        lock.withLock { toolEventsAllowed = true }
        let tool = startToolSpan(toolName, input: input)
        tool.span.setAttribute(Handoff.mode, .string(Handoff.detached))
        tool.span.setAttribute(Handoff.childEventId, .string(childId))
        tool.span.setAttribute(Handoff.name, .string(resolvedName))
        tool.setOutput(["jobId": .string(childId), "status": "accepted"])
        tool.end()
        let (u, cv) = lock.withLock { (userId, convoId) }
        return SubagentHandoff(parentEventId: eventId, parentSpanId: tool.ref.spanId, childEventId: childId,
                               name: resolvedName, userId: u, convoId: cv, traceId: tool.ref.traceId)
    }

    /// Reports that this run aborted: records an errored `ai.subagent.failed` span (unless one
    /// of its spans already errored) and finishes with output `Aborted: <reason>`. A
    /// `CancellationError` is reported as a cancellation instead.
    @discardableResult
    public func fail(_ reason: Error) async -> FlushResult {
        if reason is CancellationError { return await cancel(reason: "CancellationError") }
        return await fail(String(describing: reason))
    }

    @discardableResult
    public func fail(_ reason: String) async -> FlushResult {
        if !errorFlag.value, lock.withLock({ !finished }) {
            let span = startSpan(Handoff.abortOperationId, operationId: Handoff.abortOperationId)
            span.setError(reason)
            span.end()
        }
        return await finish(output: "Aborted: \(reason)")
    }

    /// Reports that this run was cancelled: the one outcome its spans can't express. Finishes
    /// with output `Cancelled: <reason>` and `raindrop.handoff.terminal=cancelled` on the
    /// event, which is what the launcher reads.
    @discardableResult
    public func cancel(reason: String = "cancelled by caller") async -> FlushResult {
        await finish(output: "Cancelled: \(reason)", properties: [Handoff.terminal: .string(Handoff.cancelled)])
    }

    /// Runs `body` inside a tool span; records its result, or the thrown error, and rethrows.
    public func withTool<T: Sendable>(_ name: String, input: JSONValue? = nil, parent: SpanParent? = nil,
                                      output: (T) -> JSONValue = { .string(String(describing: $0)) },
                                      isolation: isolated (any Actor)? = #isolation,
                                      _ body: () async throws -> T) async rethrows -> T {
        let tool = startToolSpan(name, input: input, parent: parent)
        return try await run(tool.span, end: { tool.end() }, output: { tool.setOutput(output($0)) },
                             isolation: isolation, body)
    }

    /// Runs `body` inside a new span that is `Span.current` for its duration, so model calls,
    /// tools and spans started inside nest under it automatically. Ends the span (marking it
    /// failed if `body` throws) and rethrows.
    public func withSpan<T: Sendable>(_ name: String, operationId: String = "ai.task",
                                      attributes: [String: JSONValue] = [:], parent: SpanParent? = nil,
                                      isolation: isolated (any Actor)? = #isolation,
                                      _ body: (Span) async throws -> T) async rethrows -> T {
        let span = startSpan(name, parent: parent, operationId: operationId, attributes: attributes)
        return try await run(span, end: { span.end() }, output: { _ in }, isolation: isolation) { try await body(span) }
    }

    /// Runs a subagent inline, as part of this event: its model calls, tools and spans nest
    /// under one tool span tagged `raindrop.agent.role=subagent`, which Raindrop shows as a
    /// subagent within this turn (and, where enabled, expands in place).
    ///
    /// For a subagent that runs on its own (a background task, another process) and should be
    /// its own event, use `subagent(name:input:childEventId:)` + `RaindropClient.beginSubagent`.
    public func inlineSubagent<T: Sendable>(_ name: String = "subagent", input: JSONValue? = nil,
                                            parent: SpanParent? = nil,
                                            output: (T) -> JSONValue = { .string(String(describing: $0)) },
                                            isolation: isolated (any Actor)? = #isolation,
                                            _ body: () async throws -> T) async rethrows -> T {
        let resolved = name.isEmpty ? "subagent" : name
        let tool = startToolSpan(resolved, input: input, parent: parent)
        tool.span.setAttribute("raindrop.agent.role", "subagent")
        tool.span.setAttribute("raindrop.subagent.name", .string(resolved))
        return try await run(tool.span, end: { tool.end() }, output: { tool.setOutput(output($0)) },
                             isolation: isolation, body)
    }

    /// Shared scope runner: current span for `body`, error status on throw, always ended.
    private func run<T: Sendable>(_ span: Span, end: () -> Void, output: (T) -> Void,
                                  isolation: isolated (any Actor)?,
                                  _ body: () async throws -> T) async rethrows -> T {
        do {
            let value = try await span.withCurrent(isolation: isolation, body)
            output(value)
            end()
            return value
        } catch {
            span.setError(String(describing: error))
            end()
            throw error
        }
    }
}

/// The ids that link a detached subagent to the turn that launched it. Plain data: keep it,
/// pass it to a task, or encode it (`Codable`) to hand to another process.
public struct SubagentHandoff: Sendable, Codable, Hashable {
    /// The launching turn's event id.
    public var parentEventId: String
    /// The dispatch span's id (16 hex characters), if one was recorded.
    public var parentSpanId: String?
    /// The child run's own event id.
    public var childEventId: String
    public var name: String
    /// Defaults for the child's user and conversation (taken from the parent turn).
    public var userId: String?
    public var convoId: String?
    /// The dispatch span's trace id (32 hex characters), if one was recorded.
    public var traceId: String?

    public init(parentEventId: String, parentSpanId: String? = nil, childEventId: String = UUID().uuidString.lowercased(),
                name: String = "subagent", userId: String? = nil, convoId: String? = nil, traceId: String? = nil) {
        self.parentEventId = parentEventId
        self.parentSpanId = parentSpanId
        self.childEventId = childEventId
        self.name = name
        self.userId = userId
        self.convoId = convoId
        self.traceId = traceId
    }

    // MARK: Header carrier (shared by every Raindrop SDK)

    /// The handoff as request headers, for a child in another service: `x-raindrop-handoff`
    /// and `baggage` carry the `raindrop-*` fields (W3C baggage encoding), plus a W3C
    /// `traceparent` when the ids are W3C-shaped. Send all of them: instrumented HTTP clients
    /// rewrite `traceparent` and `baggage`, and `x-raindrop-handoff` survives that. Read them
    /// back with `SubagentHandoff(headers:)`, in this SDK or any other Raindrop SDK.
    ///
    /// Only accept a carrier from services you trust: it names the event the child reports under.
    public var headers: [String: String] {
        let fields = Self.encodeBaggage([
            (CarrierField.eventId, parentEventId),
            (CarrierField.childEventId, childEventId),
            (CarrierField.name, name),
            (CarrierField.convoId, convoId),
            (CarrierField.userId, userId),
            (CarrierField.dispatchSpanId, parentSpanId),
            (CarrierField.traceId, traceId),
        ])
        var out = [CarrierField.header: fields, "baggage": fields]
        if let traceId, let parentSpanId, Self.isHex(traceId, count: 32), Self.isHex(parentSpanId, count: 16) {
            out["traceparent"] = "00-\(traceId.lowercased())-\(parentSpanId.lowercased())-01"
        }
        return out
    }

    /// Reads a carrier produced by any Raindrop SDK (header names are case-insensitive).
    /// `x-raindrop-handoff` wins over `baggage`, which wins over `traceparent`. Returns nil
    /// when the headers name no parent and child event, or name one field twice with two
    /// different values; the child should then run as an unlinked event.
    public init?(headers: [String: String]) {
        var lower: [String: String] = [:]
        for (key, value) in headers { lower[key.lowercased()] = value }
        guard let fromBaggage = Self.decodeBaggage(lower["baggage"]),
              let fromHeader = Self.decodeBaggage(lower[CarrierField.header]) else { return nil }
        var fields = fromBaggage
        fields.merge(fromHeader) { _, header in header }
        var traceFromParent: String?
        var spanFromParent: String?
        if let tp = lower["traceparent"] {
            let parts = tp.split(separator: "-").map(String.init)
            if parts.count == 4, Self.isHex(parts[1], count: 32), Self.isHex(parts[2], count: 16) {
                traceFromParent = parts[1].lowercased()
                spanFromParent = parts[2].lowercased()
            }
        }
        guard let parent = fields[CarrierField.eventId], !parent.isEmpty,
              let child = fields[CarrierField.childEventId], !child.isEmpty else { return nil }
        self.init(parentEventId: parent,
                  parentSpanId: fields[CarrierField.dispatchSpanId] ?? spanFromParent,
                  childEventId: child,
                  name: fields[CarrierField.name] ?? "subagent",
                  userId: fields[CarrierField.userId],
                  convoId: fields[CarrierField.convoId],
                  traceId: fields[CarrierField.traceId] ?? traceFromParent)
    }

    private enum CarrierField {
        static let header = "x-raindrop-handoff"
        static let eventId = "raindrop-event-id"
        static let childEventId = "raindrop-child-event-id"
        static let name = "raindrop-handoff-name"
        static let convoId = "raindrop-convo-id"
        static let userId = "raindrop-user-id"
        static let traceId = "raindrop-trace-id"
        static let dispatchSpanId = "raindrop-dispatch-span-id"
    }

    /// Characters left unescaped: what JavaScript's `encodeURIComponent` leaves alone, so
    /// every SDK writes the same bytes.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    private static func encodeBaggage(_ entries: [(String, String?)]) -> String {
        entries.compactMap { key, value in
            guard let value, !value.isEmpty else { return nil }
            return "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
        }.joined(separator: ",")
    }

    /// Fields of one baggage-encoded header; nil when a key appears twice with two values.
    private static func decodeBaggage(_ header: String?) -> [String: String]? {
        guard let header, !header.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for part in header.split(separator: ",") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces)
            // Baggage entry properties follow `;`; carrier fields never use them.
            let raw = part[part.index(after: eq)...].split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let value = trimmed.removingPercentEncoding ?? trimmed
            guard !key.isEmpty else { continue }
            if let existing = out[key], existing != value { return nil }
            out[key] = value
        }
        return out
    }

    private static func isHex(_ s: String, count: Int) -> Bool {
        s.count == count && s.allSatisfy(\.isHexDigit)
    }

    /// Reverse reference stamped on every span of the child.
    var childAttributes: [String: JSONValue] {
        var a: [String: JSONValue] = [
            Handoff.parentEventId: .string(parentEventId),
            Handoff.name: .string(name),
            Handoff.agentRole: .string(Handoff.subagentRole),
        ]
        if let parentSpanId, !parentSpanId.isEmpty { a[Handoff.parentSpanId] = .string(parentSpanId) }
        return a
    }
}

/// Attribute names of the detached handoff, spelled exactly as the TypeScript and Python
/// SDKs emit them.
enum Handoff {
    static let mode = "raindrop.handoff.mode"
    static let childEventId = "raindrop.handoff.childEventId"
    static let parentEventId = "raindrop.handoff.parentEventId"
    static let parentSpanId = "raindrop.handoff.parentSpanId"
    static let name = "raindrop.handoff.name"
    static let terminal = "raindrop.handoff.terminal"
    static let agentRole = "raindrop.agent.role"
    static let detached = "detached"
    static let subagentRole = "subagent"
    static let cancelled = "cancelled"
    static let toolEventsKey = "ai.telemetry.metadata.raindrop.toolEvents"
    static let toolEventsAllow = "allow"
    static let abortOperationId = "ai.subagent.failed"
}
