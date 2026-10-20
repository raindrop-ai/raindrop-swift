import Foundation
import Raindrop
import SwiftUI

/// The app's Raindrop wiring, written the way an app team would: one client for the app's
/// lifetime, owned by a `@MainActor` model, calls made from the main actor.
///
/// Test knobs come from the launch environment (set by the UI tests):
/// - `RD_SINK`: ingest base URL (the capture server), default `http://localhost:8790`
/// - `RD_FLUSH_INTERVAL`: background send interval in seconds (large = only explicit or
///   lifecycle flushes deliver)
/// - `RD_RESET_STORAGE=1`: delete the SDK's offline storage and saved state before starting
/// - `RD_WORKSHOP=1`: also mirror to `<sink>/workshop` (Raindrop Workshop path)
/// - `RD_NO_LIFECYCLE=1`: turn off the SDK's app-lifecycle handling
/// - `RD_STORAGE_PROTECTION`: `complete` | `completeUnlessOpen` | `none` (default: until first unlock)
@MainActor
final class AppModel: ObservableObject {
    @Published var status = "ready"
    @Published var steps = 0

    let client: RaindropClient
    private static let openKey = "raindrop.test.openInteraction"

    init() {
        let env = ProcessInfo.processInfo.environment
        if env["RD_RESET_STORAGE"] == "1" {
            if let dir = RaindropConfiguration.defaultStorageDirectory {
                try? FileManager.default.removeItem(at: dir)
            }
            UserDefaults.standard.removeObject(forKey: Self.openKey)
        }
        let sink = env["RD_SINK"] ?? "http://localhost:8790"
        var config = RaindropConfiguration(writeKey: env["RD_WRITE_KEY"] ?? "test-key", projectId: "ios-app-tests")
        config.endpoint = URL(string: sink + "/v1/")!
        if let raw = env["RD_FLUSH_INTERVAL"], let seconds = Double(raw) {
            config.flushInterval = .milliseconds(Int64(seconds * 1000))
        }
        config.redactPii = true
        if env["RD_WORKSHOP"] == "1" {
            config.localWorkshopURL = URL(string: sink + "/workshop")
        }
        switch env["RD_STORAGE_PROTECTION"] {
        case "complete": config.storageProtection = .complete
        case "completeUnlessOpen": config.storageProtection = .completeUnlessOpen
        case "none": config.storageProtection = StorageProtection.none
        default: break
        }
        if env["RD_NO_LIFECYCLE"] == "1" {
            config.handleAppLifecycle = false   // negative control for the background-flush test
        }
        config.debug = true
        client = RaindropClient(configuration: config)
    }

    // MARK: Actions (buttons)

    func trackAi() {
        let id = client.trackAi(AiEvent(userId: "ios-user", event: "ios_track_ai", input: "hello from iOS",
                                        output: "hi from the model", model: "test-model", convoId: "ios-convo"))
        status = "queued \(id)"
    }

    func flush() async {
        let r = await client.flush()
        status = "flushed delivered=\(r.delivered) pending=\(r.pending) timedOut=\(r.timedOut)"
    }

    /// A full agent turn from the main actor: scope, tool, inline subagent with a model call.
    func runInteraction() async {
        status = "running"
        let ix = client.begin(BeginOptions(userId: "ios-user", event: "ios_agent_turn", input: "Status of order A1002?",
                                           model: "claude-sonnet-4-5", convoId: "ios-convo",
                                           properties: ["screen": "orders"]))
        do {
            let answer = try await ix.withSpan("agent.run", operationId: "ai.workflow") { _ in
                let order = try await ix.withTool("lookup_order", input: ["order_id": "A1002"]) { () async throws -> String in
                    try await Task.sleep(for: .milliseconds(50))
                    return "processing"
                }
                return try await ix.inlineSubagent("order-worker", input: .string(order)) { () async throws -> String in
                    let llm = ix.startLlmSpan("anthropic.messages", provider: "anthropic", model: "claude-sonnet-4-5",
                                              input: "Summarize order status: \(order)")
                    llm.setOutput("Order A1002 is processing.")
                    llm.setUsage(TokenUsage(inputTokens: 12, outputTokens: 6))
                    llm.end()
                    self.steps += 1   // main-actor state inside the closure
                    return "Order A1002 is processing."
                }
            }
            let r = await ix.finish(output: answer)
            status = "interaction done \(ix.eventId) delivered=\(r.delivered) pending=\(r.pending)"
        } catch {
            await ix.fail(error)
            status = "error \(error)"
        }
    }

    /// PII in the event, a model span and a tool span; `redactPii` must scrub all of it.
    func trackPII() async {
        let pii = "I'm Jane Doe, jane.doe@example.com, 415-555-0134, 123 Main Street"
        let ix = client.begin(BeginOptions(userId: "ios-user", event: "ios_pii_turn", input: pii))
        let llm = ix.startLlmSpan("anthropic.messages", model: "claude-sonnet-4-5", input: pii)
        llm.setOutput("Noted jane.doe@example.com")
        llm.end()
        ix.trackTool("lookup_customer", input: ["query": .string(pii)], output: "found 415-555-0134")
        let r = await ix.finish(output: "Thanks, I'll email jane.doe@example.com")
        status = "pii done delivered=\(r.delivered) pending=\(r.pending)"
    }

    /// Hot-path cost on the main thread: 500 trackAi (2 KB input), 500 signals, 500 identify.
    func hotPath() {
        let input = String(repeating: "x", count: 2_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<500 {
                let id = client.trackAi(AiEvent(userId: "ios-user", event: "ios_hot_path", input: input, output: "ok"))
                client.trackSignal(Signal(eventId: id, name: "thumbs_up"))
                client.identify(userId: "ios-user-\(i)", traits: ["i": .int(Int64(i))])
            }
        }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        status = String(format: "hotpath ms=%.1f", ms)
    }

    /// Opens an interaction and saves its id + begin time, as an app would before being suspended.
    func beginOpen() {
        let began = Date()
        let ix = client.begin(BeginOptions(userId: "ios-user", event: "ios_long_turn", input: "long-running question",
                                           timestamp: began))
        UserDefaults.standard.set(["id": ix.eventId, "began": began.timeIntervalSince1970], forKey: Self.openKey)
        status = "open \(ix.eventId)"
    }

    /// After a relaunch: finish the saved interaction by id.
    func resumeFinish() async {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.openKey),
              let id = saved["id"] as? String, let began = saved["began"] as? Double else {
            status = "nothing to resume"
            return
        }
        let ix = client.resumeInteraction(eventId: id, beganAt: Date(timeIntervalSince1970: began))
        let r = await ix.finish(output: "finished after relaunch")
        UserDefaults.standard.removeObject(forKey: Self.openKey)
        status = "resumed \(id) delivered=\(r.delivered) pending=\(r.pending)"
    }

    /// Offline-storage location, backup exclusion, and the bundled privacy manifest.
    func diagnostics() {
        var excluded = "n/a"
        var files = 0
        var protection = "n/a"
        if let dir = RaindropConfiguration.defaultStorageDirectory,
           FileManager.default.fileExists(atPath: dir.path) {
            let values = try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
            excluded = String(values?.isExcludedFromBackup ?? false)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            files = names.count
            if let first = names.first,
               let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(first).path),
               let type = attrs[.protectionKey] as? FileProtectionType {
                protection = type.rawValue
            }
        }
        let manifestBundle = Self.privacyManifestBundle() ?? "none"
        status = "diag excluded=\(excluded) files=\(files) protection=\(protection) manifest=\(manifestBundle)"
    }

    /// Name of the resource bundle inside the app that carries the SDK's PrivacyInfo.xcprivacy.
    static func privacyManifestBundle() -> String? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "bundle" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("PrivacyInfo.xcprivacy").path) {
                return url.lastPathComponent
            }
        }
        return nil
    }
}
