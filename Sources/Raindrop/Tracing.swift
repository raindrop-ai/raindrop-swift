import Foundation

/// Saved identity of a span (hex, as in W3C trace context). Persist it to parent spans
/// recorded later, possibly in another process.
public struct SpanRef: Sendable, Hashable, Codable {
    /// 32 hex characters.
    public let traceId: String
    /// 16 hex characters.
    public let spanId: String

    public init(traceId: String, spanId: String) {
        self.traceId = traceId.lowercased()
        self.spanId = spanId.lowercased()
    }

    var isValid: Bool {
        traceId.count == 32 && spanId.count == 16 && (traceId + spanId).allSatisfy(\.isHexDigit)
    }
}

/// Parent of a new span. When a span is started without one, it nests under the current
/// span (`Span.current`) if that span belongs to the same event; otherwise it starts a new trace.
public enum SpanParent: Sendable {
    /// A live span.
    case span(Span)
    /// Saved ids, e.g. from another process.
    case ref(SpanRef)
    /// Start a new trace, ignoring the current span.
    case root
}

/// The span that new spans nest under by default, carried with the current Swift task
/// (task-local). Child tasks created with `Task {}` or `async let` inherit it;
/// `Task.detached` doesn't.
enum SpanScope {
    @TaskLocal static var current: Span?
}

/// One chat message on an LLM span.
public struct LlmMessage: Sendable, Equatable {
    public var role: String
    public var content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
    public static func system(_ c: String) -> LlmMessage { .init(role: "system", content: c) }
    public static func user(_ c: String) -> LlmMessage { .init(role: "user", content: c) }
    public static func assistant(_ c: String) -> LlmMessage { .init(role: "assistant", content: c) }
}

/// Provider-reported token counts (canonical `gen_ai.usage.*` attributes).
public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadInputTokens: Int?
    public var cacheWriteInputTokens: Int?
    public var reasoningTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadInputTokens: Int? = nil,
                cacheWriteInputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// A tool the model was offered, recorded as `ai.prompt.tools`.
public struct ToolDeclaration: Sendable, Equatable {
    public var name: String
    public var description: String?
    /// JSON Schema of the tool input, recorded as given.
    public var inputSchema: JSONValue?
    public init(name: String, description: String? = nil, inputSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Everything a span needs from its client / interaction, captured at start.
struct SpanContext: Sendable {
    var pipeline: Pipeline?
    var maxTextChars: Int
    var appGit: AppGitSnapshot
    var eventId: String?
    var association: [String: String] = [:]   // user_id / convo_id / event
    /// Stamped on every span (subagent reverse link, tool-events opt-in). Never overrides span-set keys.
    var extraAttributes: [String: JSONValue] = [:]
    /// Set when a span ends with an error (so `fail()` knows whether to record an abort span).
    var errorFlag: ErrorFlag?
}

/// Thread-safe "an errored span was seen" marker shared by an interaction's spans.
final class ErrorFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false
    func set() { lock.withLock { seen = true } }
    var value: Bool { lock.withLock { seen } }
}

/// A span exported to `/v1/traces` as OTLP JSON when it ends. Thread-safe; `end()` is
/// idempotent and only queues the span (no network on your thread).
public final class Span: @unchecked Sendable {
    public let name: String
    /// This span's ids, for parenting later spans (also across processes).
    public let ref: SpanRef

    private let parentSpanId: String?
    private let start: Date
    private let context: SpanContext
    private let lock = NSLock()
    private var attributes: [String: JSONValue] = [:]
    private var order: [String] = []
    private var errorMessage: String?
    private var ended = false

    init(name: String, parent: SpanParent?, start: Date?, context: SpanContext) {
        self.name = name
        self.start = start ?? Date()
        self.context = context
        var parentRef: SpanRef?
        switch parent {
        case .span(let s)?: parentRef = s.ref
        case .ref(let r)?: parentRef = r.isValid ? r : nil
        case .root?: break
        case nil:
            // Ambient parent, but only within one event: a detached subagent (its own
            // event) or a span for another event never nests into this trace.
            if let ambient = SpanScope.current, ambient.context.eventId == context.eventId {
                parentRef = ambient.ref
            }
        }
        self.parentSpanId = parentRef?.spanId
        self.ref = SpanRef(traceId: parentRef?.traceId ?? Self.randomHex(bytes: 16), spanId: Self.randomHex(bytes: 8))
    }

    /// The span new spans nest under by default in this task (see `withCurrent`).
    public static var current: Span? { SpanScope.current }

    /// Runs `body` with this span as `Span.current`, so spans started inside it (for the
    /// same event) nest under it without passing `parent:`. Doesn't end the span.
    ///
    /// Runs on the caller's actor (e.g. `@MainActor`), so `body` needn't be `Sendable`.
    public func withCurrent<T>(isolation: isolated (any Actor)? = #isolation,
                               _ body: () async throws -> T) async rethrows -> T {
        try await SpanScope.$current.withValue(self) { try await body() }
    }

    /// Synchronous variant of `withCurrent(_:)`.
    public func withCurrent<T>(_ body: () throws -> T) rethrows -> T {
        try SpanScope.$current.withValue(self) { try body() }
    }

    /// False for spans from a disabled client or with tracing off.
    public var isRecording: Bool { context.pipeline != nil }

    public func setAttribute(_ key: String, _ value: JSONValue) {
        lock.withLock {
            guard !ended else { return }
            if attributes[key] == nil { order.append(key) }
            attributes[key] = value
        }
    }

    public func setAttributes(_ values: [String: JSONValue]) {
        for key in values.keys.sorted() { setAttribute(key, values[key]!) }
    }

    func removeAttributes(where predicate: (String) -> Bool) {
        lock.withLock {
            for key in order where predicate(key) { attributes[key] = nil }
            order.removeAll(where: predicate)
        }
    }

    func text(_ s: String) -> JSONValue { .string(Truncation.truncate(s, limit: context.maxTextChars)) }

    /// Marks the span as failed (OTLP status ERROR) with a message.
    public func setError(_ message: String) {
        lock.withLock { if !ended { errorMessage = message } }
    }

    /// Ends the span and queues it for export. Later calls are ignored.
    public func end(at endTime: Date? = nil) {
        let snapshot: ([String: JSONValue], [String], String?)? = lock.withLock {
            guard !ended else { return nil }
            ended = true
            return (attributes, order, errorMessage)
        }
        guard let (attrs, keys, error) = snapshot, let pipeline = context.pipeline else { return }
        let end = max(endTime ?? Date(), start)   // never a negative duration

        var final: [(String, JSONValue)] = []
        var seen = Set<String>()
        func add(_ k: String, _ v: JSONValue) { if seen.insert(k).inserted { final.append((k, v)) } }
        for k in keys { if let v = attrs[k] { add(k, v) } }
        if let eventId = context.eventId, !eventId.isEmpty {
            add("ai.telemetry.metadata.raindrop.eventId", .string(eventId))
            add("traceloop.association.properties.event_id", .string(eventId))
        }
        for (k, v) in context.association.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
            add("traceloop.association.properties.\(k)", .string(v))
        }
        for (k, v) in context.extraAttributes.sorted(by: { $0.key < $1.key }) { add(k, v) }
        for (k, v) in context.appGit.values.sorted(by: { $0.key < $1.key }) { add(k, v) }
        if error != nil { context.errorFlag?.set() }

        var span: [String: JSONValue] = [
            "traceId": .string(Self.base64(hex: ref.traceId)),
            "spanId": .string(Self.base64(hex: ref.spanId)),
            "name": .string(name),
            "startTimeUnixNano": .string(Self.nanos(start)),
            "endTimeUnixNano": .string(Self.nanos(end)),
            "attributes": .array(final.map { ["key": .string($0.0), "value": Self.anyValue($0.1)] }),
            "status": error.map { ["code": 2, "message": .string($0)] } ?? ["code": 1],
        ]
        if let parentSpanId { span["parentSpanId"] = .string(Self.base64(hex: parentSpanId)) }
        pipeline.enqueue(.traces, .object(span))
    }

    // MARK: Encoding helpers

    static func anyValue(_ v: JSONValue) -> JSONValue {
        switch v {
        case .string(let s): return ["stringValue": .string(s)]
        case .int(let i): return ["intValue": .string(String(i))]
        case .double(let d): return ["doubleValue": .double(d)]
        case .bool(let b): return ["boolValue": .bool(b)]
        case .array(let items): return ["arrayValue": ["values": .array(items.map(anyValue))]]
        case .object, .null: return ["stringValue": .string(String(decoding: JSONWriter.data(v), as: UTF8.self))]
        }
    }

    static func nanos(_ d: Date) -> String {
        // A Date resolves about 0.24 µs at today's epoch, and multiplying it out as one Double
        // adds more error, so a millisecond time would not round-trip. Whole seconds plus the
        // fraction rounded to the microsecond keep every millisecond and microsecond time exact.
        let t = max(0, d.timeIntervalSince1970)
        let whole = t.rounded(.down)
        let micros = UInt64(((t - whole) * 1_000_000).rounded())
        return String(UInt64(whole) * 1_000_000_000 + micros * 1_000)
    }

    static func randomHex(bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        var s = ""
        repeat {
            s = (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
        } while s.allSatisfy { $0 == "0" }   // all-zero ids are invalid in OTLP
        return s
    }

    static func base64(hex: String) -> String {
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return Data(bytes).base64EncodedString()
    }
}

/// A model call. Records the attributes Raindrop's trace views and cost tracking read:
/// `ai.prompt*` / `gen_ai.prompt.*`, `ai.response.text`, model/provider, `gen_ai.usage.*`.
public final class LlmSpan: Sendable {
    public let span: Span
    public var ref: SpanRef { span.ref }

    init(span: Span) {
        self.span = span
        span.setAttribute("traceloop.span.kind", "llm")
    }

    public func setModel(_ model: String) {
        span.setAttribute("ai.model.id", .string(model))
        span.setAttribute("gen_ai.request.model", .string(model))
        span.setAttribute("gen_ai.response.model", .string(model))
    }

    /// The model the provider says served the request, when it differs from the requested one.
    public func setResponseModel(_ model: String) {
        span.setAttribute("gen_ai.response.model", .string(model))
    }

    public func setProvider(_ provider: String) {
        span.setAttribute("ai.model.provider", .string(provider))
        span.setAttribute("gen_ai.system", .string(provider))
        span.setAttribute("gen_ai.provider.name", .string(provider))
    }

    /// Single-text prompt. Replaces any previous input or messages.
    public func setInput(_ input: String) {
        clearPrompt()
        span.setAttribute("ai.prompt", span.text(input))
        span.setAttribute("gen_ai.prompt.0.role", "user")
        span.setAttribute("gen_ai.prompt.0.content", span.text(input))
    }

    /// Chat-shaped prompt. Replaces any previous input or messages.
    public func setMessages(_ messages: [LlmMessage]) {
        clearPrompt()
        let json = JSONValue.array(messages.map { ["role": .string($0.role), "content": .string($0.content)] })
        span.setAttribute("ai.prompt.messages", span.text(String(decoding: JSONWriter.data(json), as: UTF8.self)))
        for (i, m) in messages.enumerated() {
            span.setAttribute("gen_ai.prompt.\(i).role", .string(m.role))
            span.setAttribute("gen_ai.prompt.\(i).content", span.text(m.content))
        }
    }

    public func setOutput(_ output: String) {
        span.setAttribute("ai.response.text", span.text(output))
        span.setAttribute("gen_ai.completion.0.role", "assistant")
        span.setAttribute("gen_ai.completion.0.content", span.text(output))
    }

    /// Records the tool catalog offered to the model (`ai.prompt.tools`); `[]` records an empty catalog.
    public func setTools(_ tools: [ToolDeclaration]) {
        let docs: [JSONValue] = tools.map { t in
            var o: [String: JSONValue] = ["type": "function", "name": .string(t.name)]
            if let d = t.description { o["description"] = .string(d) }
            if let s = t.inputSchema { o["inputSchema"] = s }
            return .string(String(decoding: JSONWriter.data(.object(o)), as: UTF8.self))
        }
        span.setAttribute("ai.prompt.tools", .array(docs))
    }

    /// Raw provider usage. Raindrop derives cost server-side; the SDK never sends `raindrop.usage.*`.
    public func setUsage(_ usage: TokenUsage) {
        let pairs: [(String, Int?)] = [
            ("gen_ai.usage.input_tokens", usage.inputTokens),
            ("gen_ai.usage.output_tokens", usage.outputTokens),
            ("gen_ai.usage.cache_read_input_tokens", usage.cacheReadInputTokens),
            ("gen_ai.usage.cache_write_input_tokens", usage.cacheWriteInputTokens),
            ("gen_ai.usage.reasoning_tokens", usage.reasoningTokens),
        ]
        for (key, value) in pairs { if let value { span.setAttribute(key, .int(Int64(value))) } }
    }

    public func setError(_ message: String) { span.setError(message) }
    public func end(at time: Date? = nil) { span.end(at: time) }

    private func clearPrompt() {
        span.removeAttributes { $0 == "ai.prompt" || $0 == "ai.prompt.messages" || $0.hasPrefix("gen_ai.prompt.") }
    }
}

/// A tool execution. Shows up in the event's tool calls (`traceloop.span.kind=tool`).
public final class ToolSpan: Sendable {
    public let span: Span
    public var ref: SpanRef { span.ref }
    private let started = ContinuousClock.now

    init(span: Span, name: String) {
        self.span = span
        span.setAttribute("ai.operationId", "ai.toolCall")
        span.setAttribute("traceloop.span.kind", "tool")
        span.setAttribute("traceloop.entity.name", .string(name))
    }

    public func setInput(_ input: JSONValue) {
        span.setAttribute("traceloop.entity.input", span.text(Self.stringify(input)))
    }

    public func setOutput(_ output: JSONValue) {
        span.setAttribute("traceloop.entity.output", span.text(Self.stringify(output)))
    }

    /// Marks the tool call failed (OTLP status ERROR with the message).
    public func setError(_ message: String) { span.setError(message) }

    public func end(at time: Date? = nil) {
        let elapsed = ContinuousClock.now - started
        span.setAttribute("traceloop.entity.duration_ms", .int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
        span.end(at: time)
    }

    static func stringify(_ v: JSONValue) -> String {
        if case .string(let s) = v { return s }
        return String(decoding: JSONWriter.data(v), as: UTF8.self)
    }
}
