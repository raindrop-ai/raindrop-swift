import Foundation
import Testing
@testable import Raindrop

@Suite struct ProjectRouting {
    /// Sends one payload on every route (plus validate and a Workshop mirror) and returns
    /// the project header each request carried ("" when absent).
    private func headers(projectId: String?, logs: LogSink = LogSink()) async throws -> [String: Set<String>] {
        let t = FakeTransport()
        t.script("auth", [.status(200)])
        let c = makeClient(t, logs: logs) {
            $0.projectId = projectId
            $0.localWorkshopURL = URL(string: "http://localhost:5899")
        }
        c.trackAi(AiEvent(userId: "u", event: "e", input: "x"))
        c.identify(userId: "u", traits: ["plan": "pro"])
        c.trackSignal(Signal(eventId: "e1", name: "thumbs_up"))
        c.startSpan("s").end()
        let ix = c.begin(BeginOptions(userId: "u", event: "p", input: "x"))
        await ix.finish(output: "y")
        try await c.validate()
        await c.close()
        var out: [String: Set<String>] = [:]
        for r in t.requests + t.mirrored {
            out[r.route, default: []].insert(r.headers["X-Raindrop-Project-Id"] ?? "")
        }
        return out
    }

    private let routes: Set<String> = ["events/track", "events/track_partial", "users/identify", "signals/track", "traces", "auth"]

    @Test(arguments: [nil, "", "   ", "\n", "default", " default\n"] as [String?])
    func absentBlankOrDefaultSendsNoHeader(projectId: String?) async throws {
        let logs = LogSink()
        let h = try await headers(projectId: projectId, logs: logs)
        #expect(Set(h.keys) == routes)
        #expect(h.values.allSatisfy { $0 == [""] })
        #expect(!logs.warnings.contains { $0.contains("projectId") })
    }

    @Test func validSlugIsSentOnEveryRouteTrimmed() async throws {
        let h = try await headers(projectId: "  support-prod\n")
        #expect(Set(h.keys) == routes)
        #expect(h.values.allSatisfy { $0 == ["support-prod"] })
    }

    @Test(arguments: ["Support-Prod", "support prod", "-lead", "trail-", "a_b", String(repeating: "a", count: 64)])
    func invalidSlugFallsBackToDefaultWithAWarning(projectId: String) async throws {
        let logs = LogSink()
        let h = try await headers(projectId: projectId, logs: logs)
        #expect(h.values.allSatisfy { $0 == [""] })
        #expect(logs.warnings.contains { $0.contains("ignoring invalid projectId") })
    }

    @Test func slugRules() {
        for ok in ["a", "0", "my-app", "ai-summary", String(repeating: "a", count: 63)] {
            #expect(RaindropConfiguration.isValidProjectSlug(ok), "\(ok)")
        }
        for bad in ["", "-", "a-", "-a", "A", "a.b", "a b", "é", String(repeating: "a", count: 64)] {
            #expect(!RaindropConfiguration.isValidProjectSlug(bad), "\(bad)")
        }
    }

    @Test func defaultsWhenNotPassed() {
        #expect(RaindropConfiguration(writeKey: "k").projectId == nil)
        #expect(RaindropConfiguration(writeKey: "k").projectHeader == nil)
        #expect(RaindropClient(writeKey: nil).configuration.projectHeader == nil)
    }

    @Test func offlineStorageIsSharedBetweenAbsentAndDefault() {
        // Same destination project → same queue file, so a restart doesn't strand payloads.
        let a = Storage.name(writeKey: "k", project: RaindropConfiguration(writeKey: "k").projectHeader)
        let b = Storage.name(writeKey: "k", project: RaindropConfiguration(writeKey: "k", projectId: "default").projectHeader)
        let c = Storage.name(writeKey: "k", project: RaindropConfiguration(writeKey: "k", projectId: "other").projectHeader)
        #expect(a == b && a != c)
    }
}
