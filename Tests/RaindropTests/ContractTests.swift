import Foundation
import Testing
@testable import Raindrop

private func spans(_ t: FakeTransport) -> [[String: Any]] {
    t.requests("traces").flatMap { req -> [[String: Any]] in
        let rs = (req.json as? [String: Any])?["resourceSpans"] as? [[String: Any]] ?? []
        return rs.flatMap { ($0["scopeSpans"] as? [[String: Any]] ?? []).flatMap { $0["spans"] as? [[String: Any]] ?? [] } }
    }
}

private func stringAttrs(_ span: [String: Any]) -> [String: String] {
    var out: [String: String] = [:]
    for a in span["attributes"] as? [[String: Any]] ?? [] {
        let v = a["value"] as? [String: Any] ?? [:]
        out[a["key"] as! String] = (v["stringValue"] as? String) ?? (v["intValue"] as? String)
    }
    return out
}

private func partialBodies(_ t: FakeTransport, _ id: String) -> [[String: Any]] {
    t.requests("events/track_partial").compactMap { $0.json as? [String: Any] }.filter { $0["event_id"] as? String == id }
}

private func date(_ iso: String) -> Date {
    try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso)
}

/// Delivery rules from the cross-SDK contract: what is retried and what a 2xx body reports.
@Suite struct ContractDelivery {
    @Test func a408IsRetried() async {
        let t = FakeTransport()
        t.script("events/track", [.status(408), .status(200)])
        let c = makeClient(t)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "x"))
        await c.flush()
        #expect(t.requests("events/track").count == 2)
    }

    @Test func rejectedItemsAndWarningsInA2xxAreWarnedAbout() async {
        let t = FakeTransport()
        t.script("events/track", [.status(200, body: #"{"events":[],"rejected":[{"index":0,"event_id":"e1","issues":[{"path":"user_id","message":"Required"}]}]}"#)])
        t.script("events/track_partial", [.status(200, body: #"{"events":[{"event_id":"p1"}],"warnings":[{"code":"ignored_fields","index":0,"event_id":"p1","fields":["ai_data.extra"],"message":""}]}"#)])
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "x", eventId: "e1"))
        await c.begin(BeginOptions(userId: "u", event: "p", input: "x", eventId: "p1")).finish(output: "y")
        await c.flush()
        #expect(t.requests("events/track").count == 1)   // delivered, not retried
        #expect(logs.warnings.contains { $0.contains("rejected 1 item(s)") && $0.contains("event e1 (user_id: Required)") })
        #expect(logs.warnings.contains { $0.contains("accepted 1 item(s) with changes") && $0.contains("ignored ai_data.extra") })
    }

    @Test func cleanOrUnreadable2xxBodiesStayQuiet() async {
        let t = FakeTransport()
        t.script("events/track", [.status(200, body: #"{"events":[{"event_id":"e1"}]}"#), .status(200, body: ">>> not json <<<")])
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "x"))
        await c.flush()
        c.trackAi(AiEvent(userId: "u", event: "e", input: "x"))
        await c.flush()
        #expect(logs.warnings.isEmpty)
    }
}

/// Identity rules: a begun event needs a user; a resumed one doesn't.
@Suite struct ContractIdentity {
    @Test func aBeginWithoutAUserIsNotSentUntilOneIsSet() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        let ix = c.begin(BeginOptions(userId: "", event: "chat", input: "hi", eventId: "anon"))
        await c.flush()
        #expect(partialBodies(t, "anon").isEmpty)
        #expect(logs.warnings.contains { $0.contains("no userId") })
        ix.update(InteractionUpdate(userId: "u1"))
        await ix.finish(output: "hello")
        #expect(partialBodies(t, "anon").last?["user_id"] as? String == "u1")
    }

    @Test func aResumedUpdateWithoutAUserIsSentWithAWarning() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        await c.resumeInteraction(eventId: "elsewhere").finish(output: "done")
        let body = partialBodies(t, "elsewhere").last
        #expect(body?["is_pending"] as? Bool == false)
        #expect(body?["user_id"] == nil)
        #expect(logs.warnings.contains { $0.contains("resumed interaction elsewhere without a userId") })
    }

    @Test func aResumedEmptyFinishIsNotWarnedAsEmpty() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        let ix = c.resumeInteraction(eventId: "r1")
        ix.update(InteractionUpdate(userId: "u"))
        await ix.finish()
        #expect(partialBodies(t, "r1").count == 1)
        #expect(!logs.warnings.contains { $0.contains("finished with no input or output") })
    }

    @Test func aBegunEmptyFinishIsSentWithAWarning() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        await c.begin(BeginOptions(userId: "u", event: "chat", eventId: "empty")).finish()
        #expect(partialBodies(t, "empty").count == 1)
        #expect(logs.warnings.contains { $0.contains("finished with no input or output; sending it anyway") })
    }
}

/// Retroactive tool spans: exact start and end, end wins over duration.
@Suite struct ContractRetroactiveSpans {
    @Test func endTimeGivesTheExactStartAndEnd() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "run", input: "q", eventId: "retro"))
        ix.trackTool("web_search", input: "q", output: "a",
                     startTime: date("2026-01-01T00:00:00.000Z"), endTime: date("2026-01-01T00:00:02.250Z"))
        await ix.finish(output: "done")
        let span = spans(t).first { $0["name"] as? String == "web_search" }!
        #expect(span["startTimeUnixNano"] as? String == "1767225600000000000")
        #expect(span["endTimeUnixNano"] as? String == "1767225602250000000")
        #expect(stringAttrs(span)["traceloop.entity.duration_ms"] == "2250")
    }

    @Test func endTimeWinsOverDuration() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "run", input: "q"))
        ix.trackTool("lookup", duration: .milliseconds(10),
                     startTime: date("2026-01-01T00:00:00.000Z"), endTime: date("2026-01-01T00:00:01.000Z"))
        await ix.finish(output: "done")
        let span = spans(t).first { $0["name"] as? String == "lookup" }!
        #expect(span["endTimeUnixNano"] as? String == "1767225601000000000")
    }

    @Test func millisecondTimesSurviveTheNanosecondConversion() {
        #expect(Span.nanos(date("2026-03-04T05:06:07.123Z")) == "1772600767123000000")
    }
}

/// The header carrier every Raindrop SDK writes and reads.
@Suite struct ContractHandoffCarrier {
    private let handoff = SubagentHandoff(parentEventId: "evt-parent", parentSpanId: "00f067aa0ba902b7",
                                          childEventId: "evt-child", name: "research agent", userId: "u1",
                                          convoId: "c1", traceId: "4bf92f3577b34da6a3ce929d0e0e4736")

    @Test func headersRoundTrip() {
        let h = handoff.headers
        #expect(h["traceparent"] == "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
        #expect(h["x-raindrop-handoff"] == h["baggage"])
        #expect(h["x-raindrop-handoff"]?.contains("raindrop-handoff-name=research%20agent") == true)
        #expect(SubagentHandoff(headers: h) == handoff)
    }

    @Test func headerNamesAreCaseInsensitiveAndTheRaindropHeaderWins() {
        let read = SubagentHandoff(headers: [
            "X-Raindrop-Handoff": "raindrop-event-id=evt-parent,raindrop-child-event-id=evt-child",
            "Baggage": "raindrop-event-id=other,raindrop-user-id=u2",
            "Traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        ])
        #expect(read?.parentEventId == "evt-parent")
        #expect(read?.childEventId == "evt-child")
        #expect(read?.userId == "u2")
        #expect(read?.parentSpanId == "00f067aa0ba902b7")   // from traceparent
        #expect(read?.traceId == "4bf92f3577b34da6a3ce929d0e0e4736")
    }

    @Test func aFieldRepeatedWithTwoValuesOrNoEventIdsIsRefused() {
        #expect(SubagentHandoff(headers: ["x-raindrop-handoff": "raindrop-event-id=a,raindrop-event-id=b,raindrop-child-event-id=c"]) == nil)
        #expect(SubagentHandoff(headers: ["baggage": "tenant=acme"]) == nil)
        #expect(SubagentHandoff(headers: [:]) == nil)
    }

    @Test func beginSubagentFromHeadersLinksTheChild() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let run = c.beginSubagent(headers: handoff.headers)
        run.trackTool("web_search", duration: .milliseconds(1))
        await run.finish(output: "notes")
        let a = stringAttrs(spans(t).first { $0["name"] as? String == "web_search" }!)
        #expect(a["raindrop.handoff.parentEventId"] == "evt-parent")
        #expect(a["raindrop.handoff.parentSpanId"] == "00f067aa0ba902b7")
        #expect(partialBodies(t, "evt-child").last?["user_id"] as? String == "u1")
    }

    @Test func aChildWithoutACarrierStillReports() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        let run = c.beginSubagent(headers: [:], userId: "u", event: "worker", input: "job")
        await run.finish(output: "done")
        #expect(t.requests("events/track_partial").count == 1)
        #expect(logs.warnings.contains { $0.contains("no readable subagent carrier") })
    }

    @Test func dispatchRecordsTheTraceForTheCarrier() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let turn = c.begin(BeginOptions(userId: "u", event: "turn", input: "go", eventId: "launcher"))
        let h = turn.subagent(name: "worker", childEventId: "kid")
        await turn.finish(output: "ok")
        #expect(h.traceId?.count == 32)
        #expect(h.headers["traceparent"]?.hasPrefix("00-\(h.traceId!)-\(h.parentSpanId!)") == true)
    }
}
