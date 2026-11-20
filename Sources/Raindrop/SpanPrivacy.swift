import Foundation

/// Trace span content privacy: which attributes are content, and the redaction / mask / cap
/// applied to them just before export.
enum SpanPrivacy {
    /// Last key segments that always name input or output content.
    static let contentSuffixes: Set<String> = [
        "input", "output", "inputs", "outputs", "args", "arguments", "result", "results", "content", "text",
        "messages", "prompt", "completion", "instructions", "system_instructions", "reasoning", "reasoningText",
        "thinking", "toolCalls", "tool_calls", "object", "value", "values", "intent", "query", "tool_input",
    ]
    /// Content attributes whose last segment is ambiguous on its own.
    static let contentKeys: Set<String> = [
        "ai.prompt.system", "ai.subagent.result", "agent.session.title",
        "error.message", "exception.message", "exception.stacktrace",
    ]
    /// Identifier and metadata prefixes, never content.
    static let neverTouchedPrefixes = [
        "traceloop.association.properties.", "ai.telemetry.metadata.", "ai.settings.context.", "raindrop.app.",
    ]
    /// Copies of the caller's event properties on spans count as content.
    static let eventPropertyCopyPrefixes = [
        "traceloop.association.properties.", "ai.telemetry.metadata.traceloop.association.properties.",
    ]
    static let eventPropertyCopyKeys: Set<String> = ["ai.telemetry.metadata.raindrop.properties"]
    /// Association properties the SDK writes itself (this SDK also writes `event`).
    static let sdkOwnAssociationNames: Set<String> = ["user_id", "event_id", "convo_id", "event_name", "event"]

    static func isEventPropertyCopy(_ key: String) -> Bool {
        if eventPropertyCopyKeys.contains(key) { return true }
        for prefix in eventPropertyCopyPrefixes where key.hasPrefix(prefix) {
            let name = String(key.dropFirst(prefix.count))
            return !name.isEmpty && !sdkOwnAssociationNames.contains(name) && !name.hasPrefix("raindrop.")
        }
        return false
    }

    /// Whether a span attribute carries model or tool input or output (or a copy of a caller's
    /// event property).
    static func isContentKey(_ key: String) -> Bool {
        if isEventPropertyCopy(key) { return true }
        if neverTouchedPrefixes.contains(where: key.hasPrefix) { return false }
        if contentKeys.contains(key) { return true }
        let last = key.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? key
        return contentSuffixes.contains(last)
    }

    /// One OTLP span with its content attributes and status message redacted (when `redact`),
    /// passed through the mask (when set), then capped. Returns nil if redaction failed: the
    /// span is dropped rather than sent unredacted.
    static func process(_ span: [String: JSONValue], redact: Bool, masker: Masker?, limit: Int) -> [String: JSONValue]? {
        var span = span
        var failed = false

        func transform(_ text: String, field: String) -> String {
            var out = text
            if redact {
                guard let redacted = PIIJSON.redactSpanText(out) else { failed = true; return text }
                out = redacted
            }
            if let masker { out = masker.string(out, MaskContext(kind: .span, field: field)) }
            return Truncation.truncate(out, limit: limit)
        }

        func transform(_ value: JSONValue, field: String) -> JSONValue {
            guard var o = value.objectValue else { return value }
            if let s = o["stringValue"]?.stringValue {
                o["stringValue"] = .string(transform(s, field: field))
            } else if var array = o["arrayValue"]?.objectValue, let values = array["values"]?.arrayValue {
                array["values"] = .array(values.map { transform($0, field: field) })
                o["arrayValue"] = .object(array)
            }
            return .object(o)
        }

        if let attributes = span["attributes"]?.arrayValue {
            span["attributes"] = .array(attributes.map { attr in
                guard var a = attr.objectValue, let key = a["key"]?.stringValue, isContentKey(key),
                      let value = a["value"] else { return attr }
                a["value"] = transform(value, field: key)
                return .object(a)
            })
        }
        if var status = span["status"]?.objectValue, let message = status["message"]?.stringValue {
            status["message"] = .string(transform(message, field: "status.message"))
            span["status"] = .object(status)
        }
        return failed ? nil : span
    }
}
