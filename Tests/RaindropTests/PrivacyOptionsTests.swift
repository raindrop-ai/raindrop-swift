import Foundation
import Testing
@testable import Raindrop

private let at = "\u{40}"   // keeps literal addresses out of the source
private let address = "jane.doe\(at)example.com"

private struct Boom: Error { let detail: String }

/// Span attributes and status messages from every exported span, flattened.
private func spanStrings(_ t: FakeTransport) -> [(String, String)] {
    var out: [(String, String)] = []
    for req in t.requests("traces") {
        let rs = (req.json as? [String: Any])?["resourceSpans"] as? [[String: Any]] ?? []
        for s in rs.flatMap({ ($0["scopeSpans"] as? [[String: Any]] ?? []).flatMap { $0["spans"] as? [[String: Any]] ?? [] } }) {
            for a in s["attributes"] as? [[String: Any]] ?? [] {
                let v = a["value"] as? [String: Any] ?? [:]
                if let str = v["stringValue"] as? String { out.append((a["key"] as! String, str)) }
                if let i = v["intValue"] as? String { out.append((a["key"] as! String, i)) }
            }
            if let m = (s["status"] as? [String: Any])?["message"] as? String { out.append(("status.message", m)) }
        }
    }
    return out
}

private func value(_ pairs: [(String, String)], _ key: String) -> String? { pairs.first { $0.0 == key }?.1 }

/// The three masks the conformance driver installs, as plain closures.
private let tagMask: RaindropMask = { value, ctx in
    switch value {
    case .string: return .string("<MASKED \(ctx.kind.rawValue) \(ctx.field)>")
    case .array: return []
    default: return ["masked": .string("\(ctx.kind.rawValue) \(ctx.field)")]
    }
}

@Suite struct TraceRedaction {
    private func run(_ configure: (inout RaindropConfiguration) -> Void) async -> FakeTransport {
        let t = FakeTransport()
        let c = makeClient(t, configure: configure)
        let ix = c.begin(BeginOptions(userId: "user-\(address)", event: "turn", input: "hi \(address)", eventId: "evt-1"))
        let llm = ix.startLlmSpan("m", provider: "anthropic", model: "claude", messages: [.user("DOB: 1990-01-05, \(address)")])
        llm.setOutput("Card 4111 1111 1111 1111 on file")
        llm.setUsage(TokenUsage(inputTokens: 4155550134, outputTokens: 7))
        llm.end()
        ix.trackTool("lookup", input: ["mrn": 12345, "note": .string("call 555-123-4567")], output: "ok",
                     error: "failed for \(address)")
        await ix.finish(output: "done")
        await c.flush()
        return t
    }

    @Test func redactsSpanContentOnlyWhenOn() async throws {
        let t = await run { $0.redactTracePii = true }
        let s = spanStrings(t)
        #expect(value(s, "ai.response.text") == "Card <REDACTED CREDIT CARD NUMBER> on file")
        #expect(value(s, "gen_ai.prompt.0.content") == "DOB: <REDACTED DATE OF BIRTH>, <REDACTED EMAIL>")
        // JSON-valued content: per string value, cue keys, still valid JSON.
        let toolInput = try #require(value(s, "traceloop.entity.input"))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(toolInput.utf8)) as? [String: Any])
        #expect(parsed["mrn"] as? String == "<REDACTED MEDICAL RECORD NUMBER>")
        #expect(parsed["note"] as? String == "call <REDACTED PHONE NUMBER>")
        let messages = try #require(value(s, "ai.prompt.messages"))
        #expect(messages.contains("<REDACTED DATE OF BIRTH>") && (try? JSONSerialization.jsonObject(with: Data(messages.utf8))) != nil)
        #expect(value(s, "status.message") == "failed for <REDACTED EMAIL>")
        // Identifiers and metadata are left alone.
        #expect(value(s, "traceloop.association.properties.user_id") == "user-\(address)")
        #expect(value(s, "gen_ai.usage.input_tokens") == "4155550134")
        #expect(!s.contains { $0.1.contains("jane.doe") && !$0.0.hasSuffix("user_id") })
        // Events are not touched by trace redaction alone.
        let event = t.requests("events/track_partial").map { String(decoding: $0.body, as: UTF8.self) }.joined()
        #expect(event.contains("hi jane.doe"))

        let off = spanStrings(await run { _ in })
        #expect(value(off, "ai.response.text") == "Card 4111 1111 1111 1111 on file")
    }

    @Test func spanCapAppliesAfterRedaction() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.redactTracePii = true; $0.maxTextFieldChars = 60 }
        let llm = c.startLlmSpan("m", eventId: "e1", input: String(repeating: "x", count: 20) + " reach \(address) " + String(repeating: "y", count: 60))
        llm.end()
        await c.flush()
        let prompt = value(spanStrings(t), "ai.prompt") ?? ""
        #expect(!prompt.contains("jane") && prompt.contains("<REDAC"))
        #expect(prompt.unicodeScalars.count == 60)
    }

    @Test func redactPiiStillCoversSpansForCompatibility() async {
        let s = spanStrings(await run { $0.redactPii = true })
        #expect(value(s, "ai.response.text") == "Card <REDACTED CREDIT CARD NUMBER> on file")
    }
}

@Suite struct MaskOption {
    @Test func tagMasksEveryContentFieldButNoIdentity() async throws {
        let t = FakeTransport()
        let c = makeClient(t) { $0.mask = tagMask }
        c.trackAi(AiEvent(userId: "u1", event: "e", input: "hi \(address)", output: "out", model: "m",
                          properties: ["plan": "pro"],
                          attachments: [Attachment(kind: .text, role: .input, value: "secret note")]))
        c.identify(userId: address, traits: ["email": .string(address)])
        c.trackSignal(Signal(eventId: "evt-1", name: "feedback", properties: ["note": "x"], comment: "c", after: "a"))
        await c.flush()
        let e = try #require(t.requests("events/track").first?.array.first)
        #expect(e["user_id"] as? String == "u1" && e["event"] as? String == "e")
        let ai = e["ai_data"] as? [String: Any]
        #expect(ai?["input"] as? String == "<MASKED event ai_data.input>")
        #expect(ai?["output"] as? String == "<MASKED event ai_data.output>")
        #expect(ai?["model"] as? String == "m")
        let props = try #require(e["properties"] as? [String: Any])
        #expect(props["masked"] as? String == "event properties")
        #expect(props["plan"] == nil)
        #expect(props["$context"] != nil)   // the SDK's own properties are never passed
        #expect((e["attachments"] as? [Any])?.isEmpty == true)
        let identify = try #require(t.requests("users/identify").first?.array.first)
        #expect(identify["user_id"] as? String == address)
        #expect((identify["traits"] as? [String: Any])?["masked"] as? String == "identify traits")
        let signal = try #require(t.requests("signals/track").first?.array.first)
        #expect(signal["event_id"] as? String == "evt-1" && signal["signal_name"] as? String == "feedback")
        let sp = try #require(signal["properties"] as? [String: Any])
        #expect(sp["masked"] as? String == "signal properties" && sp["comment"] == nil && sp["after"] == nil)
        #expect(signal["comment"] == nil)
    }

    @Test func failsClosedAndStillShips() async throws {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs) { $0.mask = { _, _ in throw Boom(detail: "leaked \(address)") } }
        c.trackAi(AiEvent(userId: "u1", event: "e", input: "hi \(address)", output: "out", properties: ["plan": "pro"],
                          attachments: [Attachment(kind: .text, role: .input, value: "note")]))
        let llm = c.startLlmSpan("m", eventId: "e1", input: "prompt")
        llm.setError("bad \(address)")
        llm.end()
        await c.flush()
        let e = try #require(t.requests("events/track").first?.array.first)
        let ai = e["ai_data"] as? [String: Any]
        #expect(ai?["input"] as? String == "<MASK FAILED>" && ai?["output"] as? String == "<MASK FAILED>")
        let props = try #require(e["properties"] as? [String: Any])
        #expect(props["error"] as? String == "<MASK FAILED>" && props["plan"] == nil && props["$context"] != nil)
        #expect((e["attachments"] as? [Any])?.isEmpty == true)
        let s = spanStrings(t)
        #expect(value(s, "ai.prompt") == "<MASK FAILED>")
        #expect(value(s, "status.message") == "<MASK FAILED>")
        // The warning names the error's type, never its message.
        #expect(logs.warnings.contains { $0.contains("Boom") })
        #expect(!logs.warnings.contains { $0.contains("jane") })
    }

    @Test func wrongReturnTypeFailsClosed() async throws {
        let t = FakeTransport()
        let c = makeClient(t) { $0.mask = { value, _ in value.stringValue != nil ? .int(1) : .string("nope") } }
        c.identify(userId: "u1", traits: ["a": "b"])
        c.trackAi(AiEvent(userId: "u1", event: "e", input: "x", output: "y"))
        await c.flush()
        let traits = t.requests("users/identify").first?.array.first?["traits"] as? [String: Any]
        #expect(traits?["error"] as? String == "<MASK FAILED>")
        let ai = t.requests("events/track").first?.array.first?["ai_data"] as? [String: Any]
        #expect(ai?["input"] as? String == "<MASK FAILED>")
    }

    @Test func runsAfterRedaction() async throws {
        let t = FakeTransport()
        let c = makeClient(t) {
            $0.redactPii = true
            $0.mask = { value, _ in
                if case .string(let s) = value { return .string(s + " [masked by mask\(at)example.org]") }
                return value
            }
        }
        c.trackAi(AiEvent(userId: "u1", event: "e", input: "Contact me at \(address)", output: "ok"))
        await c.flush()
        let ai = t.requests("events/track").first?.array.first?["ai_data"] as? [String: Any]
        #expect(ai?["input"] as? String == "Contact me at <REDACTED EMAIL> [masked by mask\(at)example.org]")
    }

    @Test func masksSpanContentWithAttributeNames() async throws {
        let t = FakeTransport()
        let c = makeClient(t) { $0.mask = tagMask }
        let llm = c.startLlmSpan("m", eventId: "e1", model: "claude", input: "prompt")
        llm.setOutput("answer")
        llm.setUsage(TokenUsage(inputTokens: 11, outputTokens: 7))
        llm.end()
        await c.flush()
        let s = spanStrings(t)
        #expect(value(s, "ai.prompt") == "<MASKED span ai.prompt>")
        #expect(value(s, "ai.response.text") == "<MASKED span ai.response.text>")
        #expect(value(s, "gen_ai.request.model") == "claude")
        #expect(value(s, "gen_ai.usage.input_tokens") == "11")
        #expect(value(s, "ai.telemetry.metadata.raindrop.eventId") == "e1")
    }
}
