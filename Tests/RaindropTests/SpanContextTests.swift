import Foundation
import Testing
@testable import Raindrop

/// Decoded span: name, hex ids, string attributes, status code.
private struct S {
    let name: String
    let traceId: String
    let spanId: String
    let parent: String?
    let attrs: [String: String]
    let status: Int
}

private func hex(_ b64: Any?) -> String? {
    guard let s = b64 as? String, let d = Data(base64Encoded: s) else { return nil }
    return d.map { String(format: "%02x", $0) }.joined()
}

private func spans(_ t: FakeTransport) -> [String: S] {
    var out: [String: S] = [:]
    for req in t.requests("traces") {
        let rs = (req.json as? [String: Any])?["resourceSpans"] as? [[String: Any]] ?? []
        for s in rs.flatMap({ ($0["scopeSpans"] as? [[String: Any]] ?? []).flatMap { $0["spans"] as? [[String: Any]] ?? [] } }) {
            var attrs: [String: String] = [:]
            for a in s["attributes"] as? [[String: Any]] ?? [] {
                let v = a["value"] as? [String: Any] ?? [:]
                attrs[a["key"] as! String] = (v["stringValue"] as? String) ?? (v["intValue"] as? String)
            }
            let name = s["name"] as! String
            out[name] = S(name: name, traceId: hex(s["traceId"])!, spanId: hex(s["spanId"])!,
                          parent: hex(s["parentSpanId"]), attrs: attrs,
                          status: (s["status"] as? [String: Any])?["code"] as? Int ?? 0)
        }
    }
    return out
}

@Suite struct AmbientSpans {
    @Test func spansInsideAScopeNestWithoutParent() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "turn", input: "q", eventId: "evt-1"))
        #expect(Span.current == nil)
        let answer = await ix.withSpan("agent.run", operationId: "ai.workflow") { run in
            #expect(Span.current === run)
            let llm = ix.startLlmSpan("model", model: "m", input: "q")
            llm.end()
            ix.trackTool("lookup", input: ["id": 1], output: "ok")
            return "a"
        }
        #expect(answer == "a")
        #expect(Span.current == nil)
        await ix.finish(output: "a")
        let s = spans(t)
        let run = s["agent.run"]!
        #expect(run.parent == nil)
        #expect(s["model"]!.parent == run.spanId && s["model"]!.traceId == run.traceId)
        #expect(s["lookup"]!.parent == run.spanId && s["lookup"]!.traceId == run.traceId)
    }

    @Test func inlineSubagentNestsItsWorkUnderATaggedToolSpan() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "supervisor", input: "q", eventId: "evt-2"))
        await ix.withSpan("agent.run") { _ in
            let supervisorLlm = ix.startLlmSpan("supervisor.model", input: "q")
            supervisorLlm.end()
            let result = await ix.inlineSubagent("order-worker", input: ["task": "look up A1002"]) {
                let llm = ix.startLlmSpan("worker.model", input: "look up A1002")
                llm.end()
                _ = await ix.withTool("lookup_order", input: ["order_id": "A1002"]) { "processing" }
                return "A1002 is processing"
            }
            #expect(result == "A1002 is processing")
        }
        await ix.finish(output: "done")

        let s = spans(t)
        let run = s["agent.run"]!, wrapper = s["order-worker"]!
        #expect(wrapper.parent == run.spanId)
        #expect(wrapper.attrs["raindrop.agent.role"] == "subagent")
        #expect(wrapper.attrs["raindrop.subagent.name"] == "order-worker")
        #expect(wrapper.attrs["traceloop.span.kind"] == "tool")
        #expect(wrapper.attrs["traceloop.entity.input"] == #"{"task":"look up A1002"}"#)
        #expect(wrapper.attrs["traceloop.entity.output"] == "A1002 is processing")
        #expect(wrapper.attrs["traceloop.association.properties.event_id"] == "evt-2")   // same event
        #expect(!wrapper.attrs.keys.contains { $0.hasPrefix("raindrop.handoff.") })        // not detached
        #expect(s["worker.model"]!.parent == wrapper.spanId)
        #expect(s["lookup_order"]!.parent == wrapper.spanId)
        #expect(s["supervisor.model"]!.parent == run.spanId)
        #expect(Set(s.values.map(\.traceId)).count == 1)
    }

    @Test func explicitParentAndRootOverrideTheAmbientSpan() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "q", eventId: "evt-3"))
        let other = ix.startSpan("other")
        await ix.withSpan("scope") { _ in
            ix.startSpan("explicit", parent: .span(other)).end()
            ix.startSpan("fresh", parent: .root).end()
        }
        other.end()
        await ix.finish(output: "a")
        let s = spans(t)
        #expect(s["explicit"]!.parent == s["other"]!.spanId)
        #expect(s["fresh"]!.parent == nil && s["fresh"]!.traceId != s["scope"]!.traceId)
    }

    @Test func otherEventsAndDetachedSubagentsNeverNest() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let parent = c.begin(BeginOptions(userId: "u", event: "supervisor", input: "q", eventId: "evt-p"))
        let unrelated = c.begin(BeginOptions(userId: "u", event: "other", input: "x", eventId: "evt-o"))
        await parent.withSpan("parent.run") { _ in
            unrelated.startSpan("unrelated.span").end()
            let handoff = parent.subagent(name: "bg-worker", input: "work")
            // A detached child is its own event, even when started inside the parent's scope.
            let child = c.beginSubagent(handoff, input: "work")
            child.startSpan("child.span").end()
            await child.finish(output: "done")
            // Task.detached doesn't inherit the current span either.
            await Task.detached { parent.startSpan("detached.task.span").end() }.value
            // Task {} and async let do.
            await Task { parent.startSpan("child.task.span").end() }.value
            async let x: Void = parent.startSpan("async.let.span").end()
            await x
        }
        await unrelated.finish(output: "x")
        await parent.finish(output: "a")
        let s = spans(t)
        let run = s["parent.run"]!
        #expect(s["unrelated.span"]!.parent == nil)
        #expect(s["child.span"]!.parent == nil && s["child.span"]!.traceId != run.traceId)
        #expect(s["launch_subagent"]!.parent == run.spanId)   // the dispatch is the parent's own span
        #expect(s["launch_subagent"]!.attrs["raindrop.handoff.mode"] == "detached")
        #expect(s["detached.task.span"]!.parent == nil)
        #expect(s["child.task.span"]!.parent == run.spanId)
        #expect(s["async.let.span"]!.parent == run.spanId)
    }

    @Test func errorsMarkTheScopeFailedAndRethrow() async {
        struct Boom: Error {}
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "q", eventId: "evt-4"))
        await #expect(throws: Boom.self) {
            try await ix.inlineSubagent("worker") { () async throws -> String in
                ix.startSpan("inner").end()
                throw Boom()
            }
        }
        #expect(Span.current == nil)
        await ix.finish(output: "a")
        let s = spans(t)
        #expect(s["worker"]!.status == 2)
        #expect(s["inner"]!.parent == s["worker"]!.spanId)
    }

    @Test func parallelInlineSubagentsKeepTheirOwnChildren() async {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "q", eventId: "evt-5"))
        await withTaskGroup(of: Void.self) { group in
            for name in ["w1", "w2", "w3"] {
                group.addTask {
                    _ = await ix.inlineSubagent(name) {
                        try? await Task.sleep(for: .milliseconds(Int.random(in: 1...20)))
                        ix.startSpan("\(name).step").end()
                        return name
                    }
                }
            }
        }
        await ix.finish(output: "a")
        let s = spans(t)
        for name in ["w1", "w2", "w3"] {
            #expect(s["\(name).step"]!.parent == s[name]!.spanId)
        }
    }
}

/// Main-actor callers (SwiftUI view models, top-level code) must be able to use the scoped
/// APIs with ordinary non-Sendable closures that touch main-actor state.
@MainActor
final class MainActorViewModel {
    var steps: [String] = []

    func runTurn(_ ix: Interaction) async throws -> String {
        try await ix.withSpan("agent.run") { _ in
            steps.append("run")
            let found = try await ix.withTool("lookup", input: ["id": 1]) { () async throws -> String in
                steps.append("tool")
                return "found"
            }
            return try await ix.inlineSubagent("worker", input: .string(found)) { () async throws -> String in
                steps.append("subagent")
                #expect(Span.current?.name == "worker")
                return "done"
            }
        }
    }
}

@Suite struct MainActorCallers {
    @Test @MainActor func scopedAPIsWorkFromTheMainActor() async throws {
        let t = FakeTransport()
        let c = makeClient(t)
        let ix = c.begin(BeginOptions(userId: "u", event: "e", input: "q", eventId: "evt-main"))
        let vm = MainActorViewModel()
        let out = try await vm.runTurn(ix)
        #expect(out == "done")
        #expect(vm.steps == ["run", "tool", "subagent"])
        await ix.finish(output: out)
        let sent = t.requests("traces").map { String(decoding: $0.body, as: UTF8.self) }.joined()
        #expect(sent.contains("\"worker\"") && sent.contains("\"lookup\"") && sent.contains("\"agent.run\""))
    }
}
