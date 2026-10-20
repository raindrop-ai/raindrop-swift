import Foundation
import Testing
@testable import Raindrop

@Suite struct WireShape {
    @Test func trackAiBatchesIntoOneArray() async {
        let t = FakeTransport()
        let c = makeClient(t)
        for i in 0..<3 {
            c.trackAi(AiEvent(userId: "u\(i)", event: "chat", input: "in\(i)", output: "out", model: "m", convoId: "c1"))
        }
        let result = await c.flush()
        #expect(result == FlushResult(delivered: 3))
        let reqs = t.requests("events/track")
        #expect(reqs.count == 1)
        let events = reqs[0].array
        #expect(events.count == 3)
        let e = events[0]
        #expect(e["user_id"] as? String == "u0")
        #expect(e["event"] as? String == "chat")
        #expect(UUID(uuidString: e["event_id"] as? String ?? "") != nil)
        #expect((e["timestamp"] as? String)?.hasSuffix("Z") == true)
        let ai = e["ai_data"] as? [String: Any]
        #expect(ai?["input"] as? String == "in0")
        #expect(ai?["convo_id"] as? String == "c1")
        let ctx = (e["properties"] as? [String: Any])?["$context"] as? [String: Any]
        #expect((ctx?["library"] as? [String: Any])?["name"] as? String == "raindrop-swift")
        #expect(reqs[0].headers["Authorization"] == "Bearer test-key")
    }

    @Test func plainTrackHasNoAiData() async {
        let t = FakeTransport()
        let c = makeClient(t)
        c.trackEvent(Event(userId: "u", event: "cache_hit", properties: ["n": 2, "tags": ["a", "b"]]))
        await c.flush()
        let e = t.requests("events/track")[0].array[0]
        #expect(e["ai_data"] == nil)
        let props = e["properties"] as? [String: Any]
        #expect(props?["n"] as? Int == 2)
    }

    @Test func callerEventIdAndContextWin() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let id = c.trackAi(AiEvent(userId: "u", event: "e", input: "x", eventId: "my-id", properties: ["$context": "mine"]))
        #expect(id == "my-id")
        await c.flush()
        let e = t.requests("events/track")[0].array[0]
        #expect(e["event_id"] as? String == "my-id")
        #expect((e["properties"] as? [String: Any])?["$context"] as? String == "mine")
    }

    @Test func featureFlagsAndAttachments() async {
        let t = FakeTransport()
        let c = makeClient(t)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "x", attachments: [
            Attachment(kind: .code, role: .input, value: "print(1)", name: "a.py", language: "python", additional: ["extra": 1]),
        ], featureFlags: ["exp": "b"]))
        await c.flush()
        let e = t.requests("events/track")[0].array[0]
        #expect((e["feature_flags"] as? [String: String]) == ["exp": "b"])
        let a = (e["attachments"] as? [[String: Any]])?.first
        #expect(a?["type"] as? String == "code")
        #expect(a?["language"] as? String == "python")
        #expect(a?["extra"] as? Int == 1)
    }

    @Test func identifyAndSignalShapes() async {
        let t = FakeTransport()
        let c = makeClient(t)
        c.identify(userId: "user-42", traits: ["plan": "enterprise", "seats": 25])
        c.trackSignal(Signal(eventId: "evt-1", name: "thumbs_down", type: .feedback, sentiment: .negative, comment: "off-topic"))
        await c.flush()
        let id = t.requests("users/identify")[0].array[0]
        #expect(id["user_id"] as? String == "user-42")
        #expect((id["traits"] as? [String: Any])?["seats"] as? Int == 25)
        let s = t.requests("signals/track")[0].array[0]
        #expect(s["signal_name"] as? String == "thumbs_down")
        #expect(s["signal_type"] as? String == "feedback")
        #expect(s["sentiment"] as? String == "NEGATIVE")
        #expect((s["properties"] as? [String: Any])?["comment"] as? String == "off-topic")
    }

    @Test func projectHeader() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.projectId = "support-prod" }
        c.trackEvent(Event(userId: "u", event: "e"))
        await c.flush()
        #expect(t.requests[0].headers["X-Raindrop-Project-Id"] == "support-prod")

        let t2 = FakeTransport()
        let c2 = makeClient(t2) { $0.projectId = "default" }
        c2.trackEvent(Event(userId: "u", event: "e"))
        await c2.flush()
        #expect(t2.requests[0].headers["X-Raindrop-Project-Id"] == nil)
    }

    @Test func unicodeIsPreservedByteForByte() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let text = "a\u{200F}b\u{200B}c 😀 \"q\" \\ /\n"
        c.trackAi(AiEvent(userId: "u", event: "e", input: text))
        await c.flush()
        let raw = String(decoding: t.requests[0].body, as: UTF8.self)
        #expect(raw.contains("a\u{200F}b\u{200B}c 😀 \\\"q\\\" \\\\ /\\n"))
        let ai = t.requests[0].array[0]["ai_data"] as? [String: Any]
        #expect(ai?["input"] as? String == text)
    }
}

@Suite struct Limits {
    @Test func truncationMatchesContract() {
        let marker = Truncation.marker
        #expect(Truncation.truncate("short", limit: 100) == "short")
        let exact = String(repeating: "x", count: 100)
        #expect(Truncation.truncate(exact, limit: 100) == exact)
        let long = String(repeating: "😀", count: 150)   // astral: 1 codepoint each
        let out = Truncation.truncate(long, limit: 100)
        #expect(out.unicodeScalars.count == 100)
        #expect(out.hasSuffix(marker))
    }

    @Test func inputAndOutputAreTruncatedOffTheHotPath() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.maxTextFieldChars = 50 }
        c.trackAi(AiEvent(userId: "u", event: "e", input: String(repeating: "a", count: 80), output: "ok"))
        await c.flush()
        let ai = t.requests[0].array[0]["ai_data"] as? [String: Any]
        #expect((ai?["input"] as? String)?.count == 50)
        #expect((ai?["input"] as? String)?.hasSuffix(Truncation.marker) == true)
        #expect(ai?["output"] as? String == "ok")
    }

    @Test func batchesSplitBySizeAndCount() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.maxBatchSize = 2 }
        for i in 0..<5 { c.trackEvent(Event(userId: "u", event: "e\(i)")) }
        let r = await c.flush()
        #expect(r.delivered == 5)
        #expect(t.requests("events/track").map { $0.array.count } == [2, 2, 1])
    }

    @Test func queueOverflowDropsOldestWithWarning() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs) { $0.maxQueueSize = 3 }
        for i in 0..<5 { c.trackEvent(Event(userId: "u", event: "e\(i)")) }
        await c.flush()
        let names = t.requests[0].array.compactMap { $0["event"] as? String }
        #expect(names == ["e2", "e3", "e4"])
        #expect(logs.warnings.contains { $0.contains("queue full") })
    }

    @Test func beforeSendCanEditAndDrop() async {
        let t = FakeTransport()
        let c = makeClient(t) {
            $0.beforeSend = { payload in
                guard payload.body["event"]?.stringValue != "secret" else { return nil }
                var p = payload
                p.body["properties"] = ["redacted": true]
                return p
            }
        }
        c.trackEvent(Event(userId: "u", event: "secret"))
        c.trackEvent(Event(userId: "u", event: "ok", properties: ["email": "a@b.c"]))
        let r = await c.flush()
        #expect(r.dropped == 1 && r.delivered == 1)
        let e = t.requests[0].array
        #expect(e.count == 1)
        #expect((e[0]["properties"] as? [String: Any])?["redacted"] as? Bool == true)
    }
}

@Suite struct Delivery {
    @Test func emptyFlushSendsNothing() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let r = await c.flush()
        #expect(r.isComplete)
        #expect(t.requests.isEmpty)
    }

    @Test func retry429HonoursRetryAfterWithIdenticalBody() async {
        let t = FakeTransport()
        t.script("events/track", [.status(429, headers: ["Retry-After": "0.2"]), .status(200)])
        let c = makeClient(t)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let start = ContinuousClock.now
        let r = await c.flush()
        #expect(r == FlushResult(delivered: 1))
        #expect(ContinuousClock.now - start >= .milliseconds(200))
        let reqs = t.requests("events/track")
        #expect(reqs.count == 2)
        #expect(reqs[0].body == reqs[1].body)
    }

    @Test func retryAfterIsCapped() async {
        let t = FakeTransport()
        t.script("events/track", [.status(429, headers: ["Retry-After": "3600"]), .status(200)])
        let c = makeClient(t) { $0.maxRetryAfter = .milliseconds(100) }
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let r = await c.flush()
        #expect(r.delivered == 1)
        #expect(t.requests.count == 2)
    }

    @Test func retryAfterBeyondDeadlineParksInsteadOfBlocking() async {
        let t = FakeTransport()
        t.script("events/track", [.status(429, headers: ["Retry-After": "3600"])])
        let c = makeClient(t) { $0.flushDeadline = .seconds(1) }
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let start = ContinuousClock.now
        let r = await c.flush()
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(r.pending == 1 && !r.isComplete)
    }

    @Test func serverErrorsRetryWithBackoffThenSucceed() async {
        let t = FakeTransport()
        t.script("events/track", [.status(500), .status(503), .status(200)])
        let c = makeClient(t)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let r = await c.flush()
        #expect(r.delivered == 1)
        let reqs = t.requests("events/track")
        #expect(reqs.count == 3)
        #expect(Set(reqs.map(\.body)).count == 1)
    }

    @Test(arguments: [400, 401, 403, 413])
    func non429ClientErrorsAreNotRetried(status: Int) async {
        let t = FakeTransport()
        let logs = LogSink()
        t.script("events/track", [.status(status)])
        let c = makeClient(t, logs: logs)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let r = await c.flush()
        #expect(r.dropped == 1 && r.pending == 0)
        #expect(t.requests.count == 1)
        #expect(logs.warnings.contains { $0.contains("HTTP \(status)") })
    }

    @Test func malformed2xxIsDelivered() async {
        let t = FakeTransport()
        t.script("events/track", [.status(200, body: "<html>not json")])
        let c = makeClient(t)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let r = await c.flush()
        #expect(r == FlushResult(delivered: 1))
        #expect(t.requests.count == 1)
    }

    @Test func droppedConnectionResendsIdenticalBody() async {
        let t = FakeTransport()
        t.script("events/track", [.error(.connectionLost), .status(200)])
        let c = makeClient(t)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let r = await c.flush()
        #expect(r.delivered == 1)
        let reqs = t.requests("events/track")
        #expect(reqs.count == 2 && reqs[0].body == reqs[1].body)
    }

    @Test func timeoutParksAndLaterFlushResendsSameBytes() async {
        let t = FakeTransport()
        t.script("events/track", [.error(.timedOut), .status(200)])
        let c = makeClient(t)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let first = await c.flush()
        #expect(first.pending == 1)
        #expect(t.requests.count == 1)   // not resent within the same flush
        let second = await c.flush()
        #expect(second.delivered == 1)
        #expect(t.requests[0].body == t.requests[1].body)
    }

    @Test func closeDrainsAndRejectsLaterCalls() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        c.trackAi(AiEvent(userId: "u", event: "before", input: "hi"))
        let r = await c.close()
        #expect(r.delivered == 1)
        c.trackAi(AiEvent(userId: "u", event: "after", input: "hi"))
        await c.flush()
        #expect(t.requests.count == 1)
        #expect(logs.warnings.contains { $0.contains("closed") })
    }

    @Test func flushIsBoundedByDeadlineAgainstAHungServer() async {
        let t = FakeTransport()
        t.script("events/track", [.delay(.seconds(30), then: 200)])
        let c = makeClient(t) { $0.flushDeadline = .milliseconds(300) }
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let start = ContinuousClock.now
        let r = await c.flush()
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(r.timedOut)
    }

    @Test func backgroundLoopDeliversWithoutFlush() async throws {
        let t = FakeTransport()
        let c = makeClient(t) { $0.flushInterval = .milliseconds(100) }
        c.trackAi(AiEvent(userId: "u", event: "bg", input: "hi"))
        try await Task.sleep(for: .milliseconds(600))
        #expect(t.requests("events/track").count == 1)
        _ = c
    }
}

@Suite struct HotPath {
    @Test func trackCallsNeverWaitOnTheNetwork() async {
        let t = FakeTransport()
        t.script("events/track", [.delay(.seconds(5), then: 200)])
        let c = makeClient(t) { $0.flushInterval = .milliseconds(10) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<500 {
                c.trackAi(AiEvent(userId: "u", event: "e\(i)", input: String(repeating: "x", count: 2_000), output: "ok"))
                c.trackSignal(Signal(eventId: "e\(i)", name: "thumbs_up"))
                c.identify(userId: "u\(i)", traits: ["i": .int(Int64(i))])
            }
        }
        #expect(elapsed < .milliseconds(500))
    }

    @Test func invalidInputIsDroppedWithAWarning() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs)
        c.trackAi(AiEvent(userId: "", event: "e", input: "x"))
        c.trackAi(AiEvent(userId: "u", event: "e2"))
        let r = await c.flush()
        #expect(r.delivered == 0)
        #expect(t.requests.isEmpty)
        #expect(logs.warnings.count == 2)
    }

    @Test func noWriteKeyIsANoOp() async {
        let t = FakeTransport()
        let logs = LogSink()
        let c = makeClient(t, logs: logs) { $0.writeKey = "" }
        #expect(!c.isEnabled)
        let id = c.trackAi(AiEvent(userId: "u", event: "e", input: "x"))
        #expect(!id.isEmpty)
        await c.flush()
        #expect(t.requests.isEmpty)
        #expect(logs.warnings.contains { $0.contains("disabled") })
        await #expect(throws: RaindropError.disabled) { try await c.validate() }
    }
}

@Suite struct Validate {
    @Test(arguments: [(200, nil), (401, RaindropError.unauthorized), (403, .forbiddenProject), (400, .badRequest), (500, .unexpectedStatus(500))])
    func mapsStatus(status: Int, expected: RaindropError?) async {
        let t = FakeTransport()
        t.script("v1/auth", [.status(status)])
        t.script("auth", [.status(status)])
        let c = makeClient(t)
        if let expected {
            await #expect(throws: expected) { try await c.validate() }
        } else {
            await #expect(throws: Never.self) { try await c.validate() }
        }
    }

    @Test func retryAfterParsing() {
        #expect(Pipeline.parseRetryAfter("7") == 7)
        #expect(Pipeline.parseRetryAfter(" 1.5 ") == 1.5)
        #expect(Pipeline.parseRetryAfter("garbage") == nil)
        let future = Pipeline.parseRetryAfter("Fri, 31 Dec 2100 23:59:59 GMT") ?? 0
        #expect(future > 1_000_000)
    }
}
