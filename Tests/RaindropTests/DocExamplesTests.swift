import Foundation
import Testing
@testable import Raindrop

// Compiles and runs the snippets from the Swift SDK docs page against a fake transport,
// so the docs can't drift from the API.
@Suite struct DocExamples {
    func callLLM() async throws -> String { "A calm walk then coffee." }
    func weather(for city: String) async throws -> String { "sunny" }

    @Test func docsSnippetsWork() async throws {
        let t = FakeTransport()
        let raindrop = makeClient(t)

        let interaction = raindrop.begin(BeginOptions(
            userId: "user-123", event: "chat_message",
            input: "Can you suggest a calm Saturday morning in San Francisco?",
            model: "gpt-4o", convoId: "conv-123", properties: ["surface": "chat"]))
        interaction.setProperty("stage", "retrieving")
        interaction.setProperties(["region": "us-west"])
        interaction.setInput("Can you make it a little more local?")
        interaction.addAttachments([Attachment(kind: .text, role: .input, value: "Prefers coffee and a quiet walk.", name: "preferences")])
        interaction.update(InteractionUpdate(model: "gpt-4o-mini", properties: ["retries": 1]))

        let run = interaction.startSpan("agent.run", operationId: "ai.workflow")
        let llm = interaction.startLlmSpan("anthropic.messages", provider: "anthropic", model: "claude-sonnet-4-5",
                                           messages: [.system("You are concise."), .user("What's the weather in Paris?")],
                                           tools: [ToolDeclaration(name: "get_weather", inputSchema: ["type": "object"])],
                                           parent: .span(run))
        llm.setOutput("I'll check the weather.")
        llm.setUsage(TokenUsage(inputTokens: 47, outputTokens: 11))
        llm.end()
        let forecast = try await interaction.withTool("get_weather", input: ["city": "Paris"], parent: .span(run)) {
            try await weather(for: "Paris")
        }
        #expect(forecast == "sunny")
        run.end()
        await interaction.finish(output: try await callLLM())

        let resumed = raindrop.resumeInteraction(eventId: "evt_123", beganAt: Date())
        await resumed.finish(output: "Here is a shorter version of that itinerary.")

        let eventId = raindrop.trackAi(AiEvent(userId: "user-123", event: "chat_message",
                                               input: "Who won the 2023 AFL Grand Final?",
                                               output: "Collingwood by four points!", model: "gpt-4o", convoId: "conv-123"))
        raindrop.trackEvent(Event(userId: "user-123", event: "session_started", properties: ["entrypoint": "dashboard"]))
        raindrop.trackSignal(Signal(eventId: eventId, name: "thumbs_down", type: .feedback, sentiment: .negative,
                                    comment: "Answer was off-topic"))
        raindrop.identify(userId: "user-123", traits: ["name": "Jane", "plan": "paid"])
        raindrop.trackAi(AiEvent(userId: "user-123", event: "chat_message", input: "q", output: "a",
                                 featureFlags: ["new_prompt": "variant_b"]))
        let r = await raindrop.close()
        #expect(r.isComplete)
        #expect(t.requests("traces").isEmpty == false)

        var config = RaindropConfiguration(writeKey: "YOUR_WRITE_KEY", projectId: "support-prod")
        config.redactPii = true
        config.beforeSend = { payload in
            var p = payload
            p.body["properties"] = .object([:])
            return p
        }
        config.appGit = AppGitConfig(commitSha: String(repeating: "a", count: 40), commitDirty: false, branch: "main")
        config.transport = t
        config.storageDirectory = nil
        config.handleAppLifecycle = false
        let configured = RaindropClient(configuration: config)
        t.script("auth", [.status(200)])
        try await configured.validate()
        await configured.close()
    }
}

// Snippets from the "Nesting spans" and "Subagents" docs sections.
@Suite struct DocExamplesNesting {
    func lookupOrder(_ id: String) async throws -> String { "processing" }
    func summarize(_ s: String) async throws -> String { "short" }

    @Test func nestingSnippetsWork() async throws {
        let t = FakeTransport()
        let raindrop = makeClient(t)
        let turn = raindrop.begin(BeginOptions(userId: "user-123", event: "agent_turn", input: "q"))
        let answer = try await turn.withSpan("agent.run", operationId: "ai.workflow") { _ in
            let order = try await turn.withTool("lookup_order", input: ["order_id": "A1002"]) {
                try await lookupOrder("A1002")
            }
            return try await turn.inlineSubagent("summarizer", input: .string(order)) {
                let llm = turn.startLlmSpan("anthropic.messages", provider: "anthropic", model: "claude-sonnet-4-5", input: order)
                llm.setOutput("short")
                llm.end()
                return try await summarize(order)
            }
        }
        await turn.finish(output: answer)
        let fresh = turn.startSpan("unrelated", parent: .root)
        fresh.end()
        await raindrop.close()
        #expect(answer == "short")
        #expect(t.requests("traces").isEmpty == false)
    }
}
