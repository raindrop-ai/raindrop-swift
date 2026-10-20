import Foundation
import Testing
@testable import Raindrop

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("raindrop-tests-\(UUID().uuidString)")
}

@Suite struct OfflineStorage {
    @Test func unsentPayloadsSurviveARestartByteForByte() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Run 1: ingest unreachable. close() can't deliver, so it saves to disk.
        let offline = FakeTransport()
        offline.script("events/track", Array(repeating: .error(.unreachable), count: 10))
        offline.script("events/track_partial", Array(repeating: .error(.unreachable), count: 10))
        let c1 = makeClient(offline) { $0.storageDirectory = dir }
        c1.trackAi(AiEvent(userId: "u", event: "offline", input: "hi"))
        let ix = c1.begin(BeginOptions(userId: "u", event: "turn", input: "q", eventId: "evt-offline"))
        await ix.finish(output: "a")
        let r1 = await c1.close()
        #expect(r1.pending >= 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)

        // Run 2: online. The restored payloads go out with identical bytes, and the file is cleared.
        let online = FakeTransport()
        let c2 = makeClient(online) { $0.storageDirectory = dir; $0.flushInterval = .milliseconds(50) }
        try await Task.sleep(for: .milliseconds(400))
        let r2 = await c2.flush()
        #expect(r2.pending == 0)
        let firstTrack = offline.requests("events/track").first!.body
        #expect(online.requests("events/track").map(\.body).contains(firstTrack))
        let partial = online.requests("events/track_partial").first?.json as? [String: Any]
        #expect(partial?["event_id"] as? String == "evt-offline")
        #expect(partial?["is_pending"] as? Bool == false)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    }

    @Test func checkpointSavesQueuedItemsWithoutSending() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = FakeTransport()
        let c = makeClient(t) { $0.storageDirectory = dir }
        c.trackEvent(Event(userId: "u", event: "queued"))
        await c.pipelineForTesting!.checkpoint()
        #expect(t.requests.isEmpty)
        let storage = Storage(directory: dir, name: Storage.name(writeKey: "test-key", project: nil), log: Log(debug: false, handler: nil))
        let records = storage.takeAll() ?? []
        #expect(records.count == 1 && records[0].route == .eventsTrack)
        #expect(String(decoding: records[0].body, as: UTF8.self).contains("queued"))
    }

    @Test func storageIsBoundedAndExpires() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log(debug: false, handler: { _, _ in })
        let s = Storage(directory: dir, name: "q", maxBytes: 10, maxAge: 60, log: log)
        s.write([
            .init(route: .eventsTrack, body: Data("[\"old-old\"]".utf8), savedAt: Date()),
            .init(route: .eventsTrack, body: Data("[1]".utf8), savedAt: Date()),
            .init(route: .signals, body: Data("[2]".utf8), savedAt: Date(timeIntervalSinceNow: -120)),
        ])
        let back = s.takeAll() ?? []
        #expect(back.map { String(decoding: $0.body, as: UTF8.self) } == ["[1]"])   // oldest over budget dropped; expired skipped
        #expect(s.takeAll()?.isEmpty == true)   // takeAll deletes the file
    }
}

@Suite struct Workshop {
    @Test func resolutionPrecedence() {
        var c = RaindropConfiguration(writeKey: "k")
        #expect(c.resolvedWorkshopURL(environment: [:]) == nil)
        #expect(c.resolvedWorkshopURL(environment: ["RAINDROP_WORKSHOP": "true"])?.absoluteString == "http://localhost:5899/v1/")
        #expect(c.resolvedWorkshopURL(environment: ["RAINDROP_WORKSHOP": "off"]) == nil)
        #expect(c.resolvedWorkshopURL(environment: ["RAINDROP_WORKSHOP": "http://10.0.0.2:5899"])?.absoluteString == "http://10.0.0.2:5899/v1/")
        #expect(c.resolvedWorkshopURL(environment: ["RAINDROP_LOCAL_DEBUGGER": "http://a:1/v1/", "RAINDROP_WORKSHOP": "1"])?.absoluteString == "http://a:1/v1/")
        c.localWorkshopURL = URL(string: "http://explicit:2")
        #expect(c.resolvedWorkshopURL(environment: ["RAINDROP_WORKSHOP": "1"])?.absoluteString == "http://explicit:2/v1/")
    }

    @Test func mirrorsOnceAlongsideCloudDelivery() async {
        let t = FakeTransport()
        t.script("events/track", [.error(.timedOut), .status(200)])
        let c = makeClient(t) { $0.localWorkshopURL = URL(string: "http://localhost:5899") }
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        await c.flush()
        await c.flush()
        #expect(t.requests("events/track").count == 2)   // cloud: timeout then retry
        #expect(t.mirrored.count == 1)                   // Workshop: once
        #expect(t.mirrored[0].body == t.requests[0].body)
    }

    @Test func workshopOnlyModeWithoutAKey() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.writeKey = nil; $0.localWorkshopURL = URL(string: "http://localhost:5899") }
        #expect(c.isEnabled)
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        let r = await c.flush()
        #expect(r.delivered == 1)
        #expect(t.requests.isEmpty)
        #expect(t.mirrored.count == 1)
    }
}

@Suite struct Connectivity {
    @Test func wakeRetriesParkedPayloadsImmediately() async throws {
        let t = FakeTransport()
        t.script("events/track", [.status(503, headers: ["Retry-After": "30"])])
        let c = makeClient(t) { $0.flushInterval = .milliseconds(50) }
        c.trackAi(AiEvent(userId: "u", event: "e", input: "hi"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(t.requests.count == 1)                   // parked for 30 s
        c.pipelineForTesting!.wake()
        try await Task.sleep(for: .milliseconds(200))
        #expect(t.requests.count == 2)
    }
}


@Suite struct StorageProtectionHandling {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("raindrop-prot-\(UUID().uuidString)")
    }

    private func setReadable(_ url: URL, _ readable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o600 : 0o000], ofItemAtPath: url.path)
    }

    /// Identity of the file without reading it: an atomic replace changes the inode.
    private func identity(_ url: URL) throws -> [String] {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return ["\(a[.systemFileNumber] ?? "")", "\(a[.size] ?? "")", "\(a[.modificationDate] ?? "")"]
    }

    /// A locked device makes the file unreadable. The saved data must not be deleted or
    /// overwritten while that lasts, and must be delivered once it's readable again.
    /// (Simulated with permission bits, which don't restrict root, so skipped as root.)
    @Test(.enabled(if: getuid() != 0, "permission bits don't restrict root"))
    func unreadableFileIsKeptNotOverwrittenAndRestoredLater() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = Storage.name(writeKey: "test-key", project: nil)
        let file = dir.appendingPathComponent("\(name).json")

        // Run 1 saves a payload (ingest unreachable).
        let offline = FakeTransport()
        offline.script("events/track", Array(repeating: .error(.unreachable), count: 10))
        let c1 = makeClient(offline) { $0.storageDirectory = dir }
        c1.trackAi(AiEvent(userId: "u", event: "from-run-1", input: "x"))
        await c1.close()
        let saved = try Data(contentsOf: file)
        let firstSaved = (try? JSONSerialization.jsonObject(with: saved) as? [String: Any])?["records"] as? [[String: Any]]
        let savedBody = try #require((firstSaved?.first?["body"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(String(decoding: savedBody, as: UTF8.self).contains("from-run-1"))

        // Run 2 starts "locked": the file can't be read.
        try setReadable(file, false)
        let before = try identity(file)
        let logs = LogSink()
        let failing = FakeTransport()
        failing.script("events/track", Array(repeating: .error(.unreachable), count: 10))
        let c2 = makeClient(failing, logs: logs) { $0.storageDirectory = dir; $0.flushInterval = .milliseconds(50) }
        c2.trackAi(AiEvent(userId: "u", event: "from-run-2", input: "y"))
        _ = await c2.flush()   // parks run 2's payload and tries to save it
        try await Task.sleep(for: .milliseconds(200))
        // Checked without making the file readable (the SDK retries every cycle and would
        // legitimately restore it the moment it is).
        #expect(try identity(file) == before, "previous run's file was replaced while unreadable")
        #expect(logs.warnings.contains { $0.contains("not readable yet") })

        // Unlocked: the next cycle reads it back and both runs' data goes out.
        try setReadable(file, true)
        failing.script("events/track", [])
        try await Task.sleep(for: .milliseconds(400))
        let r = await c2.flush()
        #expect(r.pending == 0)
        let bodies = failing.requests("events/track").map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies.contains { $0.contains("from-run-1") })
        #expect(bodies.contains { $0.contains("from-run-2") })
        #expect(failing.requests("events/track").contains { $0.body == savedBody }, "run 1 payload not resent byte-for-byte")
        await c2.close()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func corruptFileIsDiscardedWithAWarning() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("q.json")
        try Data("not json".utf8).write(to: file)
        let logs = LogSink()
        let s = Storage(directory: dir, name: "q", log: Log(debug: false, handler: logs.handler))
        #expect(s.takeAll()?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(logs.warnings.contains { $0.contains("discarded") })
    }

    @Test(arguments: [StorageProtection.completeUntilFirstUserAuthentication, .completeUnlessOpen, .complete, .none])
    func everyProtectionRoundTrips(_ protection: StorageProtection) {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Storage(directory: dir, name: "q", protection: protection, log: Log(debug: false, handler: nil))
        s.write([.init(route: .eventsTrack, body: Data("[1]".utf8), savedAt: Date())])
        #expect(s.takeAll()?.map(\.body) == [Data("[1]".utf8)])
    }

    #if canImport(Darwin)
    @Test func protectionMapsToTheDataProtectionWriteOption() {
        let log = Log(debug: false, handler: nil)
        let dir = tempDir()
        let expected: [(StorageProtection, Data.WritingOptions)] = [
            (.completeUntilFirstUserAuthentication, .completeFileProtectionUntilFirstUserAuthentication),
            (.completeUnlessOpen, .completeFileProtectionUnlessOpen),
            (.complete, .completeFileProtection),
            (.none, .noFileProtection),
        ]
        for (protection, option) in expected {
            #expect(Storage(directory: dir, name: "q", protection: protection, log: log).protectionOption == option)
        }
    }
    #endif

    @Test func defaultProtectionIsUnchanged() {
        #expect(RaindropConfiguration(writeKey: "k").storageProtection == .completeUntilFirstUserAuthentication)
    }
}
