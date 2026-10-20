import XCTest

/// End-to-end tests of the Raindrop SDK inside a real iOS app on the simulator. The app sends
/// to capture_server.py on the host; tests drive the UI and read back what was received.
final class RaindropAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        CaptureServer.reset()
    }

    override func tearDown() {
        app?.terminate()
    }

    // MARK: Helpers

    private func launch(flushInterval: Double = 1, resetStorage: Bool = true, extra: [String: String] = [:]) {
        app = XCUIApplication()
        var env = ["RD_SINK": CaptureServer.base, "RD_FLUSH_INTERVAL": String(flushInterval)]
        if resetStorage { env["RD_RESET_STORAGE"] = "1" }
        env.merge(extra) { _, new in new }
        app.launchEnvironment = env
        app.launch()
        XCTAssertTrue(app.staticTexts["status"].waitForExistence(timeout: 30), "app didn't launch")
    }

    private func tap(_ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no button \(id)")
        button.tap()
    }

    @discardableResult
    private func waitStatus(_ prefix: String, timeout: TimeInterval = 30) -> String {
        let label = app.staticTexts["status"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if label.label.hasPrefix(prefix) { return label.label }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("status never started with '\(prefix)'; last: \(label.label)")
        return label.label
    }

    @discardableResult
    private func waitRequests(timeout: TimeInterval = 20, _ description: String,
                              until done: ([Captured]) -> Bool) -> [Captured] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [Captured] = []
        while Date() < deadline {
            last = CaptureServer.requests()
            if done(last) { return last }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("timed out waiting for \(description); got \(last.map { "\($0.route) \($0.status)" })")
        return last
    }

    private func delivered(_ requests: [Captured], _ route: String) -> [Captured] {
        requests.filter { $0.route == route && $0.status == 200 }
    }

    // MARK: Tests

    /// Basic delivery from an app: batched events/track with auth, project and SDK headers.
    func testEventDeliversFromTheApp() {
        launch()
        tap("trackAi")
        let reqs = waitRequests("events/track") { !self.delivered($0, "events/track").isEmpty }
        let req = delivered(reqs, "events/track")[0]
        let events = req.json as? [[String: Any]]
        XCTAssertEqual(events?.first?["event"] as? String, "ios_track_ai")
        XCTAssertEqual(req.headers["Authorization"], "Bearer test-key")
        XCTAssertEqual(req.headers["X-Raindrop-Project-Id"], "ios-app-tests")
        XCTAssertTrue(req.headers["User-Agent"]?.hasPrefix("raindrop-swift/") ?? false)
    }

    /// Going to the background sends what's queued, even though the background loop would
    /// not run for an hour (flush interval 3600 s).
    func testBackgroundingFlushesQueuedEvents() {
        launch(flushInterval: 3600)
        tap("trackAi")
        waitStatus("queued")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(delivered(CaptureServer.requests(), "events/track").isEmpty, "sent before backgrounding")
        XCUIDevice.shared.press(.home)
        waitRequests(timeout: 15, "events/track after backgrounding") { !self.delivered($0, "events/track").isEmpty }
        app.activate()
    }

    /// Negative control: with the SDK's lifecycle handling off, backgrounding sends nothing,
    /// so the test above really exercises the lifecycle hook.
    func testBackgroundingSendsNothingWithoutLifecycleHandling() {
        launch(flushInterval: 3600, extra: ["RD_NO_LIFECYCLE": "1"])
        tap("trackAi")
        waitStatus("queued")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(delivered(CaptureServer.requests(), "events/track").isEmpty,
                      "something other than the lifecycle hook delivered on background")
        app.activate()
    }

    /// Ingest is down; the app is backgrounded and then killed. On the next launch, with ingest
    /// back, everything goes out, unchanged byte-for-byte where it was already attempted, and
    /// the offline file is cleared.
    func testUnsentDataSurvivesKillAndRelaunch() {
        CaptureServer.setMode("down")
        launch(flushInterval: 3600)
        tap("trackAi")
        waitStatus("queued")
        tap("runInteraction")
        waitStatus("interaction done", timeout: 40)
        let firstRun = CaptureServer.requests()
        XCTAssertFalse(firstRun.filter { $0.route == "events/track" }.isEmpty, "events/track never attempted")
        XCTAssertFalse(firstRun.filter { $0.route == "events/track_partial" }.isEmpty, "partial never attempted")
        XCTAssertTrue(firstRun.allSatisfy { $0.status == 503 }, "ingest should be down")
        tap("diagnostics")
        let before = waitStatus("diag")
        print("before kill: \(before); first-run attempts: \(firstRun.map(\.route))")
        XCTAssertTrue(before.contains("files=1"), "offline file should exist before the kill: \(before)")
        XCUIDevice.shared.press(.home)        // lifecycle flush fails (503) and checkpoints to disk
        Thread.sleep(forTimeInterval: 4)
        app.terminate()                       // killed while suspended

        CaptureServer.setMode("ok")
        launch(flushInterval: 1, resetStorage: false)
        let reqs = waitRequests(timeout: 30, "events, final partial and spans after relaunch") { reqs in
            let track = self.delivered(reqs, "events/track")
            let partial = self.delivered(reqs, "events/track_partial").contains {
                ($0.json as? [String: Any])?["is_pending"] as? Bool == false
            }
            return !track.isEmpty && partial && !OtlpSpan.all(in: reqs).isEmpty
        }
        let attemptedBodies = Set(firstRun.map(\.body))
        for route in ["events/track", "events/track_partial"] {
            let sent = delivered(reqs, route)
            XCTAssertTrue(sent.contains { attemptedBodies.contains($0.body) },
                          "\(route) should be resent byte-for-byte after relaunch")
        }
        XCTAssertTrue(delivered(reqs, "events/track").contains { $0.text.contains("ios_track_ai") })
        XCTAssertTrue(OtlpSpan.all(in: reqs).contains { $0.name == "order-worker" })

        tap("diagnostics")
        let diag = waitStatus("diag")
        XCTAssertTrue(diag.contains("files=0"), "offline file should be cleared: \(diag)")
    }

    /// An interaction left open when the app was killed is finished after relaunch by id,
    /// keeping its begin time.
    func testInteractionResumesAfterRelaunch() throws {
        launch()
        tap("beginOpen")
        let status = waitStatus("open ")
        let eventId = String(status.dropFirst("open ".count))
        let pending = waitRequests("pending begin") { reqs in
            self.delivered(reqs, "events/track_partial").contains { ($0.json as? [String: Any])?["event_id"] as? String == eventId }
        }
        let begin = try XCTUnwrap(delivered(pending, "events/track_partial").first?.json as? [String: Any])
        XCTAssertEqual(begin["is_pending"] as? Bool, true)
        app.terminate()

        launch(resetStorage: false)
        tap("resumeFinish")
        waitStatus("resumed \(eventId)")
        let reqs = waitRequests("finished partial") { reqs in
            self.delivered(reqs, "events/track_partial").contains {
                let o = $0.json as? [String: Any]
                return o?["event_id"] as? String == eventId && o?["is_pending"] as? Bool == false
            }
        }
        let final = try XCTUnwrap(delivered(reqs, "events/track_partial").compactMap { $0.json as? [String: Any] }
            .last { $0["event_id"] as? String == eventId })
        XCTAssertEqual((final["ai_data"] as? [String: Any])?["output"] as? String, "finished after relaunch")
        XCTAssertEqual(final["timestamp"] as? String, begin["timestamp"] as? String, "begin time kept")
    }

    /// A main-actor agent turn: scope, tool, inline subagent; spans nest without passing parents.
    func testInteractionWithInlineSubagentFromTheMainActor() throws {
        launch()
        tap("runInteraction")
        let status = waitStatus("interaction done")
        XCTAssertTrue(status.contains("pending=0"), status)
        let reqs = waitRequests("spans") { OtlpSpan.all(in: $0).count >= 4 }
        let spans = Dictionary(OtlpSpan.all(in: reqs).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let run = try XCTUnwrap(spans["agent.run"])
        let worker = try XCTUnwrap(spans["order-worker"])
        let tool = try XCTUnwrap(spans["lookup_order"])
        let llm = try XCTUnwrap(spans["anthropic.messages"])
        XCTAssertEqual(worker.attributes["raindrop.agent.role"], "subagent")
        XCTAssertEqual(worker.parentSpanId, run.spanId)
        XCTAssertEqual(tool.parentSpanId, run.spanId)
        XCTAssertEqual(llm.parentSpanId, worker.spanId)
        XCTAssertEqual(Set([run.traceId, worker.traceId, tool.traceId, llm.traceId]).count, 1)
        let finals = delivered(reqs, "events/track_partial").compactMap { $0.json as? [String: Any] }
        XCTAssertTrue(finals.contains { $0["event"] as? String == "ios_agent_turn" && $0["is_pending"] as? Bool == false })
    }

    /// redactPii scrubs the event and span content on the device; nothing raw leaves the app.
    func testPIIIsRedactedBeforeLeavingTheDevice() {
        launch()
        tap("trackPII")
        waitStatus("pii done")
        let reqs = waitRequests("pii spans") { !OtlpSpan.all(in: $0).isEmpty && !self.delivered($0, "events/track_partial").isEmpty }
        let all = reqs.map(\.text).joined(separator: "\n")
        for raw in ["jane.doe@example.com", "415-555-0134", "123 Main Street"] {
            XCTAssertFalse(all.contains(raw), "raw PII sent: \(raw)")
        }
        XCTAssertTrue(all.contains("<REDACTED EMAIL>"))
    }

    /// Calls made on the main thread stay cheap: 1,500 calls (500 trackAi with 2 KB input,
    /// 500 signals, 500 identify) in well under a frame budget per call.
    func testHotPathOnTheMainThread() throws {
        launch(flushInterval: 3600)
        tap("hotPath")
        let status = waitStatus("hotpath")
        let ms = try XCTUnwrap(Double(status.replacingOccurrences(of: "hotpath ms=", with: "")))
        print("hot path: 1,500 calls on the main thread took \(ms) ms")
        XCTAssertLessThan(ms, 750, "1,500 hot-path calls took \(ms) ms on the main thread")
    }

    /// Offline storage lives in Application Support, excluded from backup; the privacy
    /// manifest is bundled in the app.
    func testOfflineStorageAndPrivacyManifest() {
        CaptureServer.setMode("down")
        launch(flushInterval: 3600)
        tap("trackAi")
        tap("flush")
        waitStatus("flushed")
        tap("diagnostics")
        let diag = waitStatus("diag")
        print("diagnostics: \(diag)")
        XCTAssertTrue(diag.contains("excluded=true"), diag)
        XCTAssertTrue(diag.contains("files=1"), diag)
        XCTAssertFalse(diag.contains("manifest=none"), "PrivacyInfo.xcprivacy not bundled: \(diag)")

        CaptureServer.setMode("ok")
        tap("flush")      // parked for Retry-After; a later cycle or explicit flush delivers
        Thread.sleep(forTimeInterval: 1)
        tap("flush")
        waitStatus("flushed")
    }

    /// `.complete` protection: offline storage still persists across a kill and relaunch.
    /// Wherever the OS reports a protection class, it must be the configured one.
    func testCompleteProtectionPersistsAcrossRelaunch() {
        CaptureServer.setMode("down")
        launch(flushInterval: 3600, extra: ["RD_STORAGE_PROTECTION": "complete"])
        tap("trackAi")
        tap("flush")
        waitStatus("flushed")
        tap("diagnostics")
        let diag = waitStatus("diag")
        print("storage protection (complete): \(diag)")
        XCTAssertTrue(diag.contains("files=1"), diag)
        if !diag.contains("protection=n/a") {
            XCTAssertTrue(diag.contains("protection=NSFileProtectionComplete "), diag)
        }
        app.terminate()

        CaptureServer.setMode("ok")
        launch(flushInterval: 1, resetStorage: false, extra: ["RD_STORAGE_PROTECTION": "complete"])
        waitRequests(timeout: 20, "saved event delivered after relaunch") { reqs in
            self.delivered(reqs, "events/track").contains { $0.text.contains("ios_track_ai") }
        }
    }

    /// The Raindrop Workshop mirror works from the simulator (ATS local networking).
    func testWorkshopMirrorFromTheSimulator() {
        launch(extra: ["RD_WORKSHOP": "1"])
        tap("trackAi")
        tap("flush")
        let reqs = waitRequests("cloud + workshop") { reqs in
            !self.delivered(reqs, "events/track").isEmpty && !self.delivered(reqs, "workshop:events/track").isEmpty
        }
        XCTAssertEqual(delivered(reqs, "events/track")[0].body, delivered(reqs, "workshop:events/track")[0].body)
    }
}
