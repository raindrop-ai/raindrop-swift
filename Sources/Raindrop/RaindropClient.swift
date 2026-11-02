import Foundation

/// The Raindrop client.
///
/// ```swift
/// let raindrop = RaindropClient(writeKey: "…", projectId: "my-app")
/// let eventId = raindrop.trackAi(AiEvent(userId: "u1", event: "chat", input: q, output: a, model: "gpt-4o"))
/// raindrop.trackSignal(Signal(eventId: eventId, name: "thumbs_up", sentiment: .positive))
/// await raindrop.close()
/// ```
///
/// `trackAi`, `trackEvent`, `identify` and `trackSignal` only add to an in-memory queue
/// and return immediately: no network, no waiting. Queued data is sent in the background
/// about once a second. `flush()` and `close()` send everything queued and return within
/// `flushDeadline` (10 s by default).
///
/// Telemetry never throws into your code: invalid input and delivery failures are logged
/// as warnings and dropped.
public final class RaindropClient: Sendable {
    public let configuration: RaindropConfiguration
    private let pipeline: Pipeline?
    private let log: Log
    private let context: JSONValue
    private let appGit: AppGitSnapshot
    private let registry = InteractionRegistry()
    private let lifecycle: LifecycleObserver?

    public init(configuration: RaindropConfiguration) {
        self.configuration = configuration
        let log = Log(debug: configuration.debug, handler: configuration.logHandler)
        self.log = log
        self.context = [
            "library": ["name": .string(RaindropSDK.libraryName), "version": .string(RaindropSDK.version)],
            "metadata": ["language": "swift"],
        ]
        self.appGit = AppGitSnapshot.resolve(configuration.appGit, environment: ProcessInfo.processInfo.environment, log: log)
        if configuration.hasInvalidProjectId {
            log.warn("project-id", "ignoring invalid projectId \"\(configuration.projectId ?? "")\": it must match "
                + "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$. No X-Raindrop-Project-Id header will be sent; "
                + "data goes to the default project.")
        }
        let environment = ProcessInfo.processInfo.environment
        let workshop = configuration.resolvedWorkshopURL(environment: environment)
        if configuration.isEnabled || workshop != nil {
            let storage = configuration.storageDirectory.map {
                Storage(directory: $0, name: Storage.name(writeKey: configuration.writeKey ?? "workshop",
                                                          project: configuration.projectHeader),
                        protection: configuration.storageProtection, log: log)
            }
            let pipeline = Pipeline(config: configuration, log: log, storage: storage, workshopURL: workshop)
            pipeline.startBackgroundLoop()
            self.pipeline = pipeline
            self.lifecycle = configuration.handleAppLifecycle
                ? LifecycleObserver(pipeline: pipeline, budget: .seconds(5), observeApp: true) : nil
            if !configuration.isEnabled { log.warn("workshop-only", "no write key; sending to the local Workshop only") }
            if let workshop { log.debug("mirroring to Workshop at \(workshop.absoluteString)") }
        } else {
            self.pipeline = nil
            self.lifecycle = nil
            log.warn("disabled", "no write key configured; telemetry is disabled")
        }
    }

    public convenience init(writeKey: String?, projectId: String? = nil) {
        self.init(configuration: RaindropConfiguration(writeKey: writeKey, projectId: projectId))
    }

    /// False when there's nowhere to send (no write key and no Workshop): every call is a no-op.
    public var isEnabled: Bool { pipeline != nil }

    var pipelineForTesting: Pipeline? { pipeline }

    // MARK: Hot path (local enqueue only)

    /// Records an AI interaction. Returns its event id (yours, or a generated UUID),
    /// for use with `trackSignal`.
    @discardableResult
    public func trackAi(_ e: AiEvent) -> String {
        let eventId = Self.resolveEventId(e.eventId)
        guard let pipeline else { return eventId }
        guard valid(userId: e.userId, event: e.event, kind: "trackAi") else { return eventId }
        guard (e.input ?? "").isEmpty == false || (e.output ?? "").isEmpty == false else {
            log.warn("invalid.trackAi.io", "trackAi needs input or output; dropping event \(e.event)")
            return eventId
        }
        var body = baseEvent(eventId: eventId, userId: e.userId, event: e.event, timestamp: e.timestamp,
                             properties: e.properties, attachments: e.attachments)
        var ai: [String: JSONValue] = [:]
        if let v = e.input { ai["input"] = .string(v) }
        if let v = e.output { ai["output"] = .string(v) }
        if let v = e.model { ai["model"] = .string(v) }
        if let v = e.convoId { ai["convo_id"] = .string(v) }
        body["ai_data"] = .object(ai)
        if !e.featureFlags.isEmpty {
            body["feature_flags"] = .object(e.featureFlags.mapValues { .string($0) })
        }
        pipeline.enqueue(.eventsTrack, .object(body))
        return eventId
    }

    /// Records a plain (non-AI) event. Returns its event id.
    @discardableResult
    public func trackEvent(_ e: Event) -> String {
        let eventId = Self.resolveEventId(e.eventId)
        guard let pipeline else { return eventId }
        guard valid(userId: e.userId, event: e.event, kind: "trackEvent") else { return eventId }
        let body = baseEvent(eventId: eventId, userId: e.userId, event: e.event, timestamp: e.timestamp,
                             properties: e.properties, attachments: e.attachments)
        pipeline.enqueue(.eventsTrack, .object(body))
        return eventId
    }

    /// Sets traits on a user.
    public func identify(userId: String, traits: [String: JSONValue] = [:]) {
        guard let pipeline else { return }
        guard !userId.isEmpty else {
            log.warn("invalid.identify", "identify needs a non-empty userId; dropping")
            return
        }
        pipeline.enqueue(.identify, ["user_id": .string(userId), "traits": .object(traits)])
    }

    /// Records a signal on an event you already sent.
    public func trackSignal(_ s: Signal) {
        guard let pipeline else { return }
        guard !s.eventId.isEmpty, !s.name.isEmpty else {
            log.warn("invalid.signal", "trackSignal needs eventId and name; dropping")
            return
        }
        var properties = s.properties
        if let comment = s.comment { properties["comment"] = .string(comment) }
        if let after = s.after { properties["after"] = .string(after) }
        var body: [String: JSONValue] = [
            "event_id": .string(s.eventId),
            "signal_name": .string(s.name),
            "signal_type": .string(s.type.rawValue),
            "properties": .object(properties),
        ]
        if let t = s.timestamp { body["timestamp"] = .string(Self.iso8601(t)) }
        if let v = s.sentiment { body["sentiment"] = .string(v.rawValue) }
        if let v = s.attachmentId { body["attachment_id"] = .string(v) }
        pipeline.enqueue(.signals, .object(body))
    }

    // MARK: Interactions

    /// Opens an interaction (partial event). Returns immediately; nothing waits on the network.
    public func begin(_ options: BeginOptions) -> Interaction {
        let eventId = Self.resolveEventId(options.eventId)
        let interaction = makeInteraction(eventId)
        if pipeline != nil, options.userId.isEmpty || options.event.isEmpty {
            log.warn("invalid.begin", "begin needs a non-empty userId and event name")
        }
        registry.put(interaction)
        interaction.seed(options)
        return interaction
    }

    /// Returns the open interaction for `eventId` if this process has it; otherwise a new
    /// handle for that id (for example after a relaunch or in another process). Only the
    /// event id is required: updates merge into the existing event. Pass `beganAt` (the
    /// original begin time) so `finish` keeps the event's original time.
    public func resumeInteraction(eventId: String, beganAt: Date? = nil) -> Interaction {
        if let live = registry.get(eventId) { return live }
        let interaction = makeInteraction(eventId)
        interaction.seedResumed(beganAt: beganAt)
        registry.put(interaction)
        return interaction
    }

    /// Opens the child side of a detached subagent: an interaction under `handoff.childEventId`
    /// whose spans all carry the link back to the launching turn
    /// (`raindrop.handoff.parentEventId` / `parentSpanId` / `name`, `raindrop.agent.role=subagent`).
    ///
    /// Works in a `Task.detached`, another thread, or another process (decode the handoff
    /// there). End it with `finish(output:)`, `fail(_:)` or `cancel(reason:)`.
    public func beginSubagent(_ handoff: SubagentHandoff, userId: String? = nil, event: String? = nil,
                              input: String? = nil, model: String? = nil, convoId: String? = nil,
                              properties: [String: JSONValue] = [:]) -> Interaction {
        let interaction = makeInteraction(handoff.childEventId)
        interaction.markSubagent(handoff.childAttributes)
        registry.put(interaction)
        interaction.seed(BeginOptions(userId: userId ?? handoff.userId ?? "", event: event ?? handoff.name,
                                      input: input, model: model, convoId: convoId ?? handoff.convoId,
                                      eventId: handoff.childEventId, properties: properties))
        return interaction
    }

    /// The child side of a detached subagent launched from another service: reads the handoff
    /// carrier from the request headers (`SubagentHandoff.headers`, written by any Raindrop
    /// SDK) and opens the child's own event. `userId` is used when the carrier names no user.
    /// With no readable carrier the child still runs and reports, as an unlinked event.
    public func beginSubagent(headers: [String: String], userId: String? = nil, event: String? = nil,
                              input: String? = nil, model: String? = nil, convoId: String? = nil,
                              properties: [String: JSONValue] = [:]) -> Interaction {
        guard var handoff = SubagentHandoff(headers: headers) else {
            if pipeline != nil {
                log.warn("handoff-carrier", "no readable subagent carrier in the headers; reporting as an unlinked event")
            }
            return begin(BeginOptions(userId: userId ?? "", event: event ?? "subagent", input: input, model: model,
                                      convoId: convoId, properties: properties))
        }
        if handoff.userId == nil || handoff.userId?.isEmpty == true { handoff.userId = userId }
        return beginSubagent(handoff, userId: handoff.userId, event: event, input: input, model: model,
                             convoId: convoId, properties: properties)
    }

    private func makeInteraction(_ eventId: String) -> Interaction {
        let registry = self.registry
        return Interaction(eventId: eventId, pipeline: pipeline, log: log, context: context, appGit: appGit,
                           spanContext: spanContext(eventId: eventId), onFinish: { registry.remove($0) })
    }

    // MARK: Tracing (standalone; prefer the Interaction methods so spans link to the event)

    func spanContext(eventId: String?) -> SpanContext {
        SpanContext(pipeline: configuration.tracingEnabled ? pipeline : nil,
                    maxTextChars: configuration.maxTextFieldChars, appGit: appGit, eventId: eventId)
    }

    /// A span not tied to an interaction. Pass `eventId` to link it to an event you sent.
    public func startSpan(_ name: String, eventId: String? = nil, parent: SpanParent? = nil,
                          operationId: String = "ai.task", attributes: [String: JSONValue] = [:],
                          startTime: Date? = nil) -> Span {
        let span = Span(name: name, parent: parent, start: startTime, context: spanContext(eventId: eventId))
        span.setAttribute("ai.operationId", .string(operationId))
        span.setAttributes(attributes)
        return span
    }

    /// A model call not tied to an interaction.
    public func startLlmSpan(_ name: String, eventId: String? = nil, provider: String? = nil, model: String? = nil,
                             input: String? = nil, messages: [LlmMessage]? = nil, tools: [ToolDeclaration]? = nil,
                             parent: SpanParent? = nil, startTime: Date? = nil) -> LlmSpan {
        let llm = LlmSpan(span: Span(name: name, parent: parent, start: startTime, context: spanContext(eventId: eventId)))
        if let provider { llm.setProvider(provider) }
        if let model { llm.setModel(model) }
        if let messages { llm.setMessages(messages) } else if let input { llm.setInput(input) }
        if let tools { llm.setTools(tools) }
        return llm
    }

    /// A tool execution not tied to an interaction.
    public func startToolSpan(_ name: String, eventId: String? = nil, input: JSONValue? = nil,
                              parent: SpanParent? = nil, startTime: Date? = nil) -> ToolSpan {
        let tool = ToolSpan(span: Span(name: name, parent: parent, start: startTime, context: spanContext(eventId: eventId)), name: name)
        if let input { tool.setInput(input) }
        return tool
    }

    // MARK: Lifecycle (bounded, durable on return)

    /// Sends everything queued so far. Returns once it's delivered, or at `flushDeadline`.
    @discardableResult
    public func flush() async -> FlushResult {
        await pipeline?.flush() ?? FlushResult()
    }

    /// Flushes, then stops the client. Later calls are dropped with a warning. Open
    /// interactions are sent as they are (still pending); finish them first if you can.
    @discardableResult
    public func close() async -> FlushResult {
        let open = registry.count
        if open > 0, pipeline != nil {
            log.warn("open-at-close", "\(open) interaction(s) still open at close; their latest state is sent as pending")
        }
        return await pipeline?.close() ?? FlushResult()
    }

    /// Checks the write key and project against `POST /v1/auth`. Doesn't send any data.
    public func validate() async throws {
        guard configuration.isEnabled else { throw RaindropError.disabled }
        let transport = configuration.transport ?? URLSessionTransport()
        var headers = ["Authorization": "Bearer \(configuration.writeKey ?? "")", "Content-Type": "application/json"]
        if let project = configuration.projectHeader { headers["X-Raindrop-Project-Id"] = project }
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(
                url: configuration.endpoint.appendingPathComponent("auth"), headers: headers,
                body: Data("{}".utf8), timeout: configuration.flushDeadline))
        } catch {
            throw RaindropError.transport("\(error)")
        }
        switch response.status {
        case 200..<300: return
        case 401: throw RaindropError.unauthorized
        case 403: throw RaindropError.forbiddenProject
        case 400: throw RaindropError.badRequest
        default: throw RaindropError.unexpectedStatus(response.status)
        }
    }

    // MARK: Helpers

    private func valid(userId: String, event: String, kind: String) -> Bool {
        if userId.isEmpty || event.isEmpty {
            log.warn("invalid.\(kind)", "\(kind) needs a non-empty userId and event name; dropping")
            return false
        }
        return true
    }

    private func baseEvent(eventId: String, userId: String, event: String, timestamp: Date?,
                           properties: [String: JSONValue], attachments: [Attachment]) -> [String: JSONValue] {
        var props = properties
        if props["$context"] == nil { props["$context"] = context }   // caller properties win
        appGit.fill(&props)
        var body: [String: JSONValue] = [
            "event_id": .string(eventId),
            "event": .string(event),
            "user_id": .string(userId),
            "timestamp": .string(Self.iso8601(timestamp ?? Date())),
            "properties": .object(props),
        ]
        if !attachments.isEmpty { body["attachments"] = .array(attachments.map(Self.encode)) }
        return body
    }

    static func encode(_ a: Attachment) -> JSONValue {
        var o = a.additional
        o["type"] = .string(a.kind.rawValue)
        o["role"] = .string(a.role.rawValue)
        o["value"] = .string(a.value)
        if let v = a.name { o["name"] = .string(v) }
        if let v = a.language { o["language"] = .string(v) }
        if let v = a.attachmentId { o["attachment_id"] = .string(v) }
        return .object(o)
    }

    static func resolveEventId(_ id: String?) -> String {
        if let id, !id.isEmpty { return id }
        return UUID().uuidString.lowercased()
    }

    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func iso8601(_ date: Date) -> String { isoStyle.format(date) }
}

/// Open interactions in this process, for `resumeInteraction`.
final class InteractionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Interaction] = [:]
    func put(_ i: Interaction) { lock.withLock { items[i.eventId] = i } }
    func get(_ id: String) -> Interaction? { lock.withLock { items[id] } }
    func remove(_ id: String) { lock.withLock { items[id] = nil } }
    var count: Int { lock.withLock { items.count } }
}
