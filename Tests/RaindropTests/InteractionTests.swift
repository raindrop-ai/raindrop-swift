import Foundation
import Testing
@testable import Raindrop

private func partials(_ t: FakeTransport) -> [[String: Any]] {
    t.requests("events/track_partial").compactMap { $0.json as? [String: Any] }
}

@Suite struct Interactions {
    @Test func beginPatchFinishAccumulates() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "chat", input: "start", model: "m", convoId: "c1"))
        ix.setProperty("first", 1)
        ix.setProperties(["second": 2])
        let r = await ix.finish(output: "end", properties: ["third": 3])
        #expect(r.isComplete)
        let sent = partials(t)
        #expect(sent.count == 1)   // coalesced: begin/patch/finish within one cycle
        let last = sent.last!
        #expect(last["event_id"] as? String == ix.eventId)
        #expect(UUID(uuidString: ix.eventId) != nil)
        #expect(last["is_pending"] as? Bool == false)
        #expect(last["user_id"] as? String == "u")
        let props = last["properties"] as? [String: Any]
        #expect(props?["first"] as? Int == 1 && props?["second"] as? Int == 2 && props?["third"] as? Int == 3)
        let ai = last["ai_data"] as? [String: Any]
        #expect(ai?["input"] as? String == "start")
        #expect(ai?["output"] as? String == "end")
        #expect(ai?["convo_id"] as? String == "c1")
        #expect(last["input"] == nil && last["output"] == nil)
    }

    @Test func pendingUpdatesAreSentInTheBackgroundWithFullState() async throws {
        let t = FakeTransport()
        let c = makeClient(t) { $0.flushInterval = .milliseconds(50) }
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "q"))
        try await Task.sleep(for: .milliseconds(300))
        ix.setProperty("stage", "retrieval")
        try await Task.sleep(for: .milliseconds(300))
        await ix.finish(output: "a")
        let sent = partials(t)
        #expect(sent.count == 3)
        #expect(sent.map { $0["is_pending"] as? Bool } == [true, true, false])
        #expect((sent[1]["properties"] as? [String: Any])?["stage"] as? String == "retrieval")
        #expect((sent[2]["ai_data"] as? [String: Any])?["input"] as? String == "q")   // full state each time
        #expect(Set(sent.map { $0["timestamp"] as? String }).count == 1)              // begin time kept
    }

    @Test func noContentNoSendUntilInputOrOutput() async throws {
        let t = FakeTransport()
        let c = makeClient(t) { $0.flushInterval = .milliseconds(50) }
        let ix = c.begin(BeginOptions(userId: "u", event: "e"))
        ix.setProperty("k", "v")
        try await Task.sleep(for: .milliseconds(250))
        #expect(partials(t).isEmpty)
        ix.setInput("now there is input")
        try await Task.sleep(for: .milliseconds(250))
        #expect(partials(t).count == 1)
        #expect((partials(t)[0]["properties"] as? [String: Any])?["k"] as? String == "v")
        await ix.finish(output: "done")
    }

    @Test func emptyFinishStillSendsButWarns() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        let ix = c.begin(BeginOptions(userId: "u", event: "e"))
        await ix.finish()
        #expect(partials(t).count == 1)
        #expect(partials(t)[0]["ai_data"] == nil)
        #expect(logs.warnings.contains { $0.contains("no input or output") })
    }

    @Test func resumeInAnotherProcessNeedsOnlyTheEventId() async {
        let t = FakeTransport()
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        let c = makeClient(t)
        let ix = c.resumeInteraction(eventId: "evt-123", beganAt: began)
        ix.setProperty("resumed", true)
        await ix.finish(output: "later")
        let p = partials(t)[0]
        #expect(p["event_id"] as? String == "evt-123")
        #expect(p["user_id"] == nil)
        #expect(p["is_pending"] as? Bool == false)
        #expect((p["timestamp"] as? String)?.hasPrefix("2027-01-15") == true)
        #expect((p["properties"] as? [String: Any])?["resumed"] as? Bool == true)
    }

    @Test func resumeReturnsTheLiveInteraction() {
        let c = makeClient(FakeTransport())
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "x", eventId: "live"))
        #expect(c.resumeInteraction(eventId: "live") === ix)
    }

    @Test func newerSnapshotSupersedesAParkedOne() async {
        let t = FakeTransport()
        t.script("events/track_partial", [.error(.timedOut), .status(200)])
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "x"))
        let first = await c.flush()
        #expect(first.pending == 1)
        await ix.finish(output: "y")
        let sent = partials(t)
        #expect(sent.count == 2)
        #expect(sent[1]["is_pending"] as? Bool == false)   // the parked pending snapshot was not resent
        #expect(await c.flush().pending == 0)
    }

    @Test func updatesAfterFinishAreIgnored() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "x"))
        await ix.finish(output: "y")
        ix.setProperty("late", true)
        #expect(await ix.finish(output: "z") == FlushResult())
        await c.flush()
        #expect(partials(t).count == 1)
        #expect(logs.warnings.contains { $0.contains("is finished") })
    }

    @Test func finishedRetryResendsIdenticalBytes() async {
        let t = FakeTransport()
        t.script("events/track_partial", [.status(429, headers: ["Retry-After": "0"]), .status(200)])
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "x"))
        await ix.finish(output: "y")
        let reqs = t.requests("events/track_partial")
        #expect(reqs.count == 2 && reqs[0].body == reqs[1].body)
    }
}

@Suite struct AppIdentity {
    let sha = String(repeating: "a", count: 40)

    @Test func configBeatsEnvironmentAndCallerWins() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.appGit = AppGitConfig(commitSha: String(repeating: "b", count: 40), commitDirty: false, branch: "main") }
        c.trackEvent(Event(userId: "u", event: "e", properties: ["raindrop.app.branch": "", "raindrop.app.commit_sha": nil]))
        let ix = c.begin(BeginOptions(userId: "u", event: "p", input: "x"))
        await ix.finish(output: "y")
        let e = t.requests("events/track")[0].array[0]["properties"] as? [String: Any]
        #expect(e?["raindrop.app.branch"] as? String == "")
        #expect(e?["raindrop.app.commit_sha"] is NSNull)
        #expect(e?["raindrop.app.commit_dirty"] as? Bool == false)
        let p = partials(t)[0]["properties"] as? [String: Any]
        #expect(p?["raindrop.app.commit_sha"] as? String == String(repeating: "b", count: 40))
    }

    @Test func environmentAndValidation() {
        let log = Log(debug: false, handler: { _, _ in })
        let env = ["RAINDROP_COMMIT_SHA": sha, "RAINDROP_COMMIT_DIRTY": "true", "RAINDROP_BRANCH": "feat"]
        let s = AppGitSnapshot.resolve(AppGitConfig(), environment: env, log: log)
        #expect(s.values == ["raindrop.app.commit_sha": .string(sha), "raindrop.app.commit_dirty": true, "raindrop.app.branch": "feat"])
        #expect(AppGitSnapshot.resolve(nil, environment: env, log: log).values.isEmpty)
        #expect(AppGitSnapshot.resolve(AppGitConfig(useEnvironment: false), environment: env, log: log).values.isEmpty)
        #expect(AppGitSnapshot.resolve(AppGitConfig(commitSha: "abc"), environment: [:], log: log).values.isEmpty)
    }
}

@Suite struct Redaction {
    @Test func matchesTypeScriptDefaults() {
        let out = PIIRedactor.redact("Mail jane.doe@example.com or call 415-555-0134. SSN 123-45-6789, card 4111 1111 1111 1111, password: hunter2, 123 Main Street.")
        #expect(out.contains("<REDACTED EMAIL>"))
        #expect(out.contains("<REDACTED PHONE NUMBER>"))
        #expect(out.contains("<REDACTED CREDIT CARD NUMBER>"))
        #expect(out.contains("<REDACTED SECRET>"))
        #expect(out.contains("<REDACTED ADDRESS>"))
        #expect(!out.contains("jane.doe") && !out.contains("hunter2") && !out.contains("4111"))
        #expect(PIIRedactor.redact("nothing sensitive here") == "nothing sensitive here")
    }

    @Test func appliesOnlyWhenEnabledAndOnlyToInputOutput() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.redactPii = true }
        c.trackAi(AiEvent(userId: "a@b.com", event: "e", input: "I'm a@b.com", output: "ok", properties: ["email": "a@b.com"]))
        await c.flush()
        let e = t.requests[0].array[0]
        #expect((e["ai_data"] as? [String: Any])?["input"] as? String == "I'm <REDACTED EMAIL>")
        #expect(e["user_id"] as? String == "a@b.com")
        #expect((e["properties"] as? [String: Any])?["email"] as? String == "a@b.com")
    }
}

private func spans(_ t: FakeTransport) -> [[String: Any]] {
    t.requests("traces").flatMap { req -> [[String: Any]] in
        let rs = (req.json as? [String: Any])?["resourceSpans"] as? [[String: Any]] ?? []
        return rs.flatMap { ($0["scopeSpans"] as? [[String: Any]] ?? []).flatMap { $0["spans"] as? [[String: Any]] ?? [] } }
    }
}

private func attrs(_ span: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for a in span["attributes"] as? [[String: Any]] ?? [] {
        let v = a["value"] as? [String: Any] ?? [:]
        out[a["key"] as! String] = v["stringValue"] ?? v["intValue"] ?? v["boolValue"] ?? v["doubleValue"] ?? v["arrayValue"]
    }
    return out
}

private func hex(_ b64: Any?) -> String {
    Data(base64Encoded: b64 as? String ?? "")!.map { String(format: "%02x", $0) }.joined()
}

@Suite struct Tracing {
    @Test func interactionSpansLinkToTheEventAndNest() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u1", event: "agent_turn", input: "weather?", convoId: "c9", eventId: "evt-9"))
        let root = ix.startSpan("agent.run", operationId: "ai.workflow")
        let llm = ix.startLlmSpan("anthropic.messages", provider: "anthropic", model: "claude-sonnet-4-5",
                                  messages: [.system("be brief"), .user("weather?")],
                                  tools: [ToolDeclaration(name: "get_weather", inputSchema: ["type": "object"])],
                                  parent: .span(root))
        llm.setOutput("I'll check.")
        llm.setUsage(TokenUsage(inputTokens: 40, outputTokens: 7, cacheReadInputTokens: 3))
        llm.end()
        _ = await ix.withTool("get_weather", input: ["city": "Paris"], parent: .span(root)) { "sunny" }
        root.end()
        await ix.finish(output: "Sunny.")

        let all = spans(t)
        #expect(all.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0["name"] as! String, $0) })
        let r = byName["agent.run"]!, l = byName["anthropic.messages"]!, tool = byName["get_weather"]!
        #expect(hex(l["parentSpanId"]) == hex(r["spanId"]))
        #expect(hex(tool["parentSpanId"]) == hex(r["spanId"]))
        #expect(hex(l["traceId"]) == hex(r["traceId"]) && hex(r["traceId"]).count == 32)

        let ra = attrs(r)
        #expect(ra["ai.operationId"] as? String == "ai.workflow")
        #expect(ra["traceloop.association.properties.event_id"] as? String == "evt-9")
        #expect(ra["ai.telemetry.metadata.raindrop.eventId"] as? String == "evt-9")
        #expect(ra["traceloop.association.properties.user_id"] as? String == "u1")
        #expect(ra["traceloop.association.properties.convo_id"] as? String == "c9")

        let la = attrs(l)
        #expect(la["traceloop.span.kind"] as? String == "llm")
        #expect(la["gen_ai.provider.name"] as? String == "anthropic")
        #expect(la["gen_ai.request.model"] as? String == "claude-sonnet-4-5")
        #expect(la["gen_ai.usage.input_tokens"] as? String == "40")
        #expect(la["gen_ai.usage.cache_read_input_tokens"] as? String == "3")
        #expect((la["ai.prompt.messages"] as? String)?.contains("be brief") == true)
        #expect(la["gen_ai.prompt.1.content"] as? String == "weather?")
        #expect(la["ai.response.text"] as? String == "I'll check.")
        #expect(la["ai.prompt.tools"] != nil)
        #expect(!la.keys.contains { $0.hasPrefix("raindrop.usage") })

        let ta = attrs(tool)
        #expect(ta["traceloop.span.kind"] as? String == "tool")
        #expect(ta["ai.operationId"] as? String == "ai.toolCall")
        #expect(ta["traceloop.entity.input"] as? String == #"{"city":"Paris"}"#)
        #expect(ta["traceloop.entity.output"] as? String == "sunny")
        #expect(ta["traceloop.entity.duration_ms"] != nil)
        #expect((tool["status"] as? [String: Any])?["code"] as? Int == 1)

        let resource = ((t.requests("traces")[0].json as? [String: Any])?["resourceSpans"] as? [[String: Any]])?[0]["resource"] as? [String: Any]
        #expect(String(describing: resource).contains("raindrop.swift-sdk"))
    }

    @Test func trackToolWithErrorAndSavedParent() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let saved = SpanRef(traceId: String(repeating: "ab", count: 16), spanId: String(repeating: "cd", count: 8))
        let ix = c.resumeInteraction(eventId: "evt-x")
        ix.trackTool("db_query", input: ["q": "select 1"], error: "connection timeout", duration: .milliseconds(50), parent: .ref(saved))
        await c.flush()
        let s = spans(t)[0]
        #expect(hex(s["traceId"]) == saved.traceId)
        #expect(hex(s["parentSpanId"]) == saved.spanId)
        #expect((s["status"] as? [String: Any])?["code"] as? Int == 2)
        #expect((s["status"] as? [String: Any])?["message"] as? String == "connection timeout")
        #expect(attrs(s)["traceloop.entity.duration_ms"] as? String == "50")
        let start = UInt64(s["startTimeUnixNano"] as! String)!, end = UInt64(s["endTimeUnixNano"] as! String)!
        #expect(end - start >= 49_000_000)
    }

    @Test func withToolRecordsThrownErrors() async {
        struct Boom: Error {}
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.resumeInteraction(eventId: "e")
        await #expect(throws: Boom.self) { try await ix.withTool("explode") { () async throws -> Int in throw Boom() } }
        await c.flush()
        #expect((spans(t)[0]["status"] as? [String: Any])?["code"] as? Int == 2)
    }

    @Test func tracingOffAndEndIdempotent() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.tracingEnabled = false }
        let s = c.startSpan("x")
        #expect(!s.isRecording)
        s.end()
        let t2 = FakeTransport()
        let c2 = makeClient(t2)
        let s2 = c2.startSpan("y")
        s2.end()
        s2.end()
        await c.flush()
        await c2.flush()
        #expect(t.requests.isEmpty)
        #expect(spans(t2).count == 1)
        #expect(attrs(spans(t2)[0])["ai.operationId"] as? String == "ai.task")
    }

    @Test func spanTextIsTruncatedAndAppGitAttached() async {
        let t = FakeTransport()
        let c = makeClient(t) {
            $0.maxTextFieldChars = 40
            $0.appGit = AppGitConfig(commitSha: String(repeating: "c", count: 40))
        }
        let llm = c.startLlmSpan("m", eventId: "e1", input: String(repeating: "z", count: 100))
        llm.end()
        await c.flush()
        let a = attrs(spans(t)[0])
        #expect((a["ai.prompt"] as? String)?.count == 40)
        #expect(a["raindrop.app.commit_sha"] as? String == String(repeating: "c", count: 40))
    }
}

@Suite struct SpanRedaction {
    let pii = "I'm jane.doe@example.com, call 415-555-0134, ship to 123 Main Street"

    private func spanAttrs(_ t: FakeTransport) -> [String: String] {
        var out: [String: String] = [:]
        for req in t.requests("traces") {
            let rs = (req.json as? [String: Any])?["resourceSpans"] as? [[String: Any]] ?? []
            for s in rs.flatMap({ ($0["scopeSpans"] as? [[String: Any]] ?? []).flatMap { $0["spans"] as? [[String: Any]] ?? [] } }) {
                for a in s["attributes"] as? [[String: Any]] ?? [] {
                    let v = a["value"] as? [String: Any] ?? [:]
                    out[a["key"] as! String] = (v["stringValue"] as? String) ?? (v["intValue"] as? String)
                }
                if let m = (s["status"] as? [String: Any])?["message"] as? String { out["status.message"] = m }
            }
        }
        return out
    }

    private func run(_ t: FakeTransport, redact: Bool, hookSaw: Seen? = nil) async {
        let c = makeClient(t) {
            $0.redactPii = redact
            if let hookSaw {
                $0.beforeSend = { p in
                    if p.route == "traces" { hookSaw.add(String(decoding: JSONWriter.data(.object(p.body)), as: UTF8.self)) }
                    return p
                }
            }
        }
        let ix = c.begin(BeginOptions(userId: "user-4155550134", event: "turn", input: pii, eventId: "evt-1"))
        let llm = ix.startLlmSpan("m", provider: "anthropic", model: "claude-sonnet-4-5",
                                  messages: [.system("be brief"), .user(pii)])
        llm.setOutput("Sure, emailing jane.doe@example.com")
        llm.setUsage(TokenUsage(inputTokens: 4155550134, outputTokens: 12))
        llm.end()
        let plain = ix.startLlmSpan("p", input: pii)
        plain.end()
        ix.trackTool("lookup", input: ["note": .string(pii)], output: "phone 415-555-0134",
                     error: "failed for jane.doe@example.com")
        _ = ix.subagent(name: "order-worker", input: .string("look up orders for jane.doe@example.com"))
        await ix.finish(output: "done")
    }

    @Test func spanContentIsRedactedAndMetadataIsNot() async {
        let t = FakeTransport()
        await run(t, redact: true)
        let a = spanAttrs(t)
        let raw = t.requests("traces").map { String(decoding: $0.body, as: UTF8.self) }.joined()
        #expect(!raw.contains("jane.doe") && !raw.contains("555-0134") && !raw.contains("123 Main"))
        #expect(a["gen_ai.prompt.1.content"]?.contains("<REDACTED EMAIL>") == true)
        #expect(a["ai.prompt.messages"]?.contains("<REDACTED PHONE NUMBER>") == true)
        #expect(a["ai.prompt"]?.contains("<REDACTED ADDRESS>") == true)
        #expect(a["ai.response.text"] == "Sure, emailing <REDACTED EMAIL>")
        #expect(a["traceloop.entity.input"]?.contains("<REDACTED EMAIL>") == true)
        #expect(raw.contains("phone <REDACTED PHONE NUMBER>"))   // tool output
        #expect(a["status.message"] == "failed for <REDACTED EMAIL>")
        let dispatchInputs = t.requests("traces").map { String(decoding: $0.body, as: UTF8.self) }
        #expect(dispatchInputs.contains { $0.contains("look up orders for <REDACTED EMAIL>") })   // subagent handoff text
        // Not content: left alone even though the phone pattern would match.
        #expect(a["traceloop.association.properties.user_id"] == "user-4155550134")
        #expect(a["gen_ai.usage.input_tokens"] == "4155550134")
        #expect(a["gen_ai.request.model"] == "claude-sonnet-4-5")
        // ai.prompt.messages stays valid JSON after redaction.
        let msgs = a["ai.prompt.messages"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]]
        #expect(msgs?.count == 2)
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    @Test func beforeSendSeesRedactedSpans() async {
        let seen = Seen()
        await run(FakeTransport(), redact: true, hookSaw: seen)
        #expect(seen.all.count == 4)   // two LLM spans, a tool span and the subagent dispatch
        #expect(seen.all.allSatisfy { !$0.contains("jane.doe") && !$0.contains("555-0134") })
        #expect(seen.all.contains { $0.contains("<REDACTED EMAIL>") })
    }

    @Test func offByDefault() async {
        let t = FakeTransport()
        await run(t, redact: false)
        let a = spanAttrs(t)
        #expect(a["ai.response.text"] == "Sure, emailing jane.doe@example.com")
        #expect(a["status.message"] == "failed for jane.doe@example.com")
    }

    @Test func redactedSpanTextStaysWithinTheCap() {
        var span: [String: JSONValue] = ["attributes": [["key": "ai.prompt", "value": ["stringValue": "a@b.co a@b.co a@b.co"]]]]
        PIIRedactor.redactSpan(&span, limit: 30)
        let text = span["attributes"]?.arrayValue?.first?.objectValue?["value"]?.objectValue?["stringValue"]?.stringValue ?? ""
        #expect(text.unicodeScalars.count <= 30)
        #expect(!text.contains("a@b.co"))
    }
}
