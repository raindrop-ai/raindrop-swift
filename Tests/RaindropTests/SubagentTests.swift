import Foundation
import Testing
@testable import Raindrop

private func allSpans(_ t: FakeTransport) -> [[String: Any]] {
    t.requests("traces").flatMap { req -> [[String: Any]] in
        let rs = (req.json as? [String: Any])?["resourceSpans"] as? [[String: Any]] ?? []
        return rs.flatMap { ($0["scopeSpans"] as? [[String: Any]] ?? []).flatMap { $0["spans"] as? [[String: Any]] ?? [] } }
    }
}

private func attrs(_ span: [String: Any]) -> [String: String] {
    var out: [String: String] = [:]
    for a in span["attributes"] as? [[String: Any]] ?? [] {
        let v = a["value"] as? [String: Any] ?? [:]
        out[a["key"] as! String] = (v["stringValue"] as? String) ?? (v["intValue"] as? String)
    }
    return out
}

private func hex(_ b64: Any?) -> String {
    Data(base64Encoded: b64 as? String ?? "")!.map { String(format: "%02x", $0) }.joined()
}

private func partial(_ t: FakeTransport, _ id: String) -> [String: Any]? {
    t.requests("events/track_partial").compactMap { $0.json as? [String: Any] }.last { $0["event_id"] as? String == id }
}

@Suite struct Subagents {
    @Test func inProcessDetachedTaskLinksChildToParent() async {
        let t = FakeTransport()
        let raindrop = makeClient(t)
        let turn = raindrop.begin(BeginOptions(userId: "u1", event: "supervisor_turn", input: "research swift", convoId: "c1", eventId: "parent-1"))
        let handoff = turn.subagent(name: "researcher", input: ["topic": "swift"])
        let llmAfter = turn.startLlmSpan("plan", model: "m")   // later spans carry the tool-events opt-in
        llmAfter.end()

        // The subagent runs in its own detached task and reports as its own event.
        let child = Task.detached {
            let run = raindrop.beginSubagent(handoff, input: "research swift")
            let llm = run.startLlmSpan("anthropic.messages", model: "claude")
            llm.setOutput("notes")
            llm.end()
            run.trackTool("web_search", input: ["q": "swift"], output: "results")
            await run.finish(output: "Swift is a language.")
        }
        await child.value
        await turn.finish(output: "Dispatched the researcher.")

        // Dispatch span on the parent.
        let spans = allSpans(t)
        let dispatch = spans.first { $0["name"] as? String == "launch_subagent" }!
        let d = attrs(dispatch)
        #expect(d["raindrop.handoff.mode"] == "detached")
        #expect(d["raindrop.handoff.childEventId"] == handoff.childEventId)
        #expect(d["raindrop.handoff.name"] == "researcher")
        #expect(d["traceloop.association.properties.event_id"] == "parent-1")
        #expect(d["ai.telemetry.metadata.raindrop.toolEvents"] == "allow")
        #expect(d["traceloop.entity.output"]?.contains("\"jobId\"") == true)
        #expect(attrs(spans.first { $0["name"] as? String == "plan" }!)["ai.telemetry.metadata.raindrop.toolEvents"] == "allow")
        #expect(hex(dispatch["spanId"]) == handoff.parentSpanId)

        // Every child span carries the reverse reference and the child's own event id.
        let childSpans = spans.filter { attrs($0)["traceloop.association.properties.event_id"] == handoff.childEventId }
        #expect(childSpans.count == 2)
        for s in childSpans {
            let a = attrs(s)
            #expect(a["raindrop.handoff.parentEventId"] == "parent-1")
            #expect(a["raindrop.handoff.parentSpanId"] == handoff.parentSpanId)
            #expect(a["raindrop.handoff.name"] == "researcher")
            #expect(a["raindrop.agent.role"] == "subagent")
            #expect(a["raindrop.handoff.mode"] == nil)
        }

        // The child is its own event, defaulting user/convo from the parent.
        let c = partial(t, handoff.childEventId)!
        #expect(c["is_pending"] as? Bool == false)
        #expect(c["user_id"] as? String == "u1")
        #expect(c["event"] as? String == "researcher")
        #expect((c["ai_data"] as? [String: Any])?["convo_id"] as? String == "c1")
        #expect(partial(t, "parent-1")?["is_pending"] as? Bool == false)
    }

    @Test func handoffIsPlainCodableDataForAnotherProcess() async throws {
        let t = FakeTransport()
        let raindrop = makeClient(t)
        // Ids the integration stored itself; no dispatch recorded in this process.
        let manual = SubagentHandoff(parentEventId: "evt-parent", parentSpanId: "0123456789abcdef", childEventId: "evt-child", name: "summarizer")
        let wire = try JSONEncoder().encode(manual)
        let decoded = try JSONDecoder().decode(SubagentHandoff.self, from: wire)
        #expect(decoded == manual)
        let run = raindrop.beginSubagent(decoded, userId: "u9", input: "summarize")
        run.startSpan("step").end()
        await run.finish(output: "summary")
        let a = attrs(allSpans(t)[0])
        #expect(a["raindrop.handoff.parentEventId"] == "evt-parent")
        #expect(a["raindrop.handoff.parentSpanId"] == "0123456789abcdef")
        #expect(partial(t, "evt-child")?["user_id"] as? String == "u9")
    }

    @Test func failRecordsAnAbortSpanOnlyWhenNothingErrored() async {
        let t = FakeTransport()
        let raindrop = makeClient(t)
        let h = SubagentHandoff(parentEventId: "p", childEventId: "c-fail")
        let run = raindrop.beginSubagent(h, userId: "u")
        await run.fail("model timeout")
        let abort = allSpans(t).first { $0["name"] as? String == "ai.subagent.failed" }!
        #expect(attrs(abort)["ai.operationId"] == "ai.subagent.failed")
        #expect(attrs(abort)["raindrop.handoff.parentEventId"] == "p")
        #expect((abort["status"] as? [String: Any])?["code"] as? Int == 2)
        #expect((partial(t, "c-fail")?["ai_data"] as? [String: Any])?["output"] as? String == "Aborted: model timeout")

        let t2 = FakeTransport()
        let r2 = makeClient(t2)
        let run2 = r2.beginSubagent(SubagentHandoff(parentEventId: "p", childEventId: "c2"), userId: "u", input: "x")
        let tool = run2.startToolSpan("db"); tool.setError("boom"); tool.end()
        await run2.fail("db failed")
        #expect(allSpans(t2).filter { $0["name"] as? String == "ai.subagent.failed" }.isEmpty)
    }

    @Test func cancelMarksTheChildEventAndCancellationErrorIsNotAFailure() async {
        let t = FakeTransport()
        let raindrop = makeClient(t)
        let run = raindrop.beginSubagent(SubagentHandoff(parentEventId: "p", childEventId: "c-cancel"), userId: "u", input: "x")
        await run.fail(CancellationError())
        let c = partial(t, "c-cancel")!
        #expect((c["properties"] as? [String: Any])?["raindrop.handoff.terminal"] as? String == "cancelled")
        #expect((c["ai_data"] as? [String: Any])?["output"] as? String == "Cancelled: CancellationError")
        #expect(allSpans(t).isEmpty)
    }
}
