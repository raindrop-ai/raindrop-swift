# raindrop-swift

Raindrop SDK for Swift (iOS 16+, macOS 13+, tvOS, watchOS, visionOS and Linux).

> **Status: beta (`0.0.8`), ready for production use.** Events, AI events, interactions
> (begin/finish/resume), signals, identify, manual tracing, offline storage and app
> lifecycle handling are all supported. The API may still change before `0.1.0`, so pin a
> version. Full docs:
> [raindrop.ai/docs/sdk/swift](https://raindrop.ai/docs/sdk/swift).

## Install

```swift
// Package.swift
.package(url: "https://github.com/raindrop-ai/raindrop-swift.git", from: "0.0.8")
// target dependency:
.product(name: "Raindrop", package: "raindrop-swift")
```

## Usage

```swift
import Raindrop

let raindrop = RaindropClient(writeKey: "<write key>", projectId: "my-app")

// Returns immediately: the event is queued and sent in the background.
let eventId = raindrop.trackAi(AiEvent(
    userId: "user-123",
    event: "chat_message",
    input: "What's the status of order A1002?",
    output: "It's processing.",
    model: "claude-sonnet-4-5",
    convoId: "conv-456",
    properties: ["surface": "chat"]
))

raindrop.trackSignal(Signal(eventId: eventId, name: "thumbs_up", type: .feedback, sentiment: .positive))

// Long-running turns: begin → updates → finish, with model and tool spans linked to the event.
let turn = raindrop.begin(BeginOptions(
    userId: "user-123",
    event: "agent_turn",
    input: question,
    convoId: "conv-456"
))

let llm = turn.startLlmSpan(
    "anthropic.messages",
    provider: "anthropic",
    model: "claude-sonnet-4-5",
    input: question
)
llm.setOutput(draft)
llm.setUsage(TokenUsage(inputTokens: 120, outputTokens: 40))
llm.end()

let order = try await turn.withTool("lookup_order", input: ["order_id": "A1002"]) {
    try await lookupOrder("A1002")
}

// Inline subagent: part of this event. Spans started inside the closure (no `parent:`)
// nest under it automatically via the task-local current span.
let summary = try await turn.inlineSubagent("summarizer", input: .string(order)) {
    try await summarize(order)
}

await turn.finish(output: answer)

// Detached subagent (experimental): its own event, linked to the turn by ids (same task,
// another task, or another process).
let handoff = turn.subagent(name: "researcher")
Task.detached {
    let run = raindrop.beginSubagent(handoff, input: "research")
    do {
        await run.finish(output: try await research())
    } catch {
        await run.fail(error)
    }
}
// In another service: send `handoff.headers` with the request, and open the child there
// from the request's headers (the carrier every Raindrop SDK writes and reads).
let child = raindrop.beginSubagent(headers: requestHeaders, input: "research")

raindrop.identify(userId: "user-123", traits: ["plan": "paid"])
raindrop.trackEvent(Event(userId: "user-123", event: "session_started"))

// Before exit (or when a serverless handler returns): send everything, bounded at 10 s.
await raindrop.close()
```

`flush()` sends without closing. `validate()` checks the write key and project against
`POST /v1/auth` without sending data. A nil or empty write key makes the client a no-op.

## Behaviour

How delivery works:

| | |
|---|---|
| Hot path | `trackAi`, `trackEvent`, `identify`, `trackSignal` append to an in-memory queue under a lock and return. No network, sleeps or serialization on your thread. |
| Delivery | A background loop sends about once a second. `events/track` batches are one JSON array per request (≤ 100 items / ~900 KB). |
| `flush` / `close` | Durable on return, bounded by `flushDeadline` (10 s). The returned `FlushResult` says what was delivered, rejected, given up on or left queued; a request still in flight at the deadline is dropped rather than resent. |
| Retries | 408, 429 and 5xx: honour `Retry-After` (capped at 30 s) or back off 0.5 s → 8 s with jitter, up to 4 attempts per cycle, then park and retry later. Other 4xx: dropped with a warning, never retried. Any 2xx counts as delivered; items it lists as `rejected` or `warnings` are logged as warnings. |
| Identical retries | Each batch is serialized once and resent byte-for-byte, keeping event ids stable. |
| Timeouts | 2 s idle timeout per request. A timed-out batch is retried on a later cycle, not inside the same `flush`. |
| Limits | `input` / `output` truncated at 1,000,000 codepoints with `...[truncated by raindrop]`. No caps on properties or attachments. Unicode preserved byte-for-byte. |
| Bounded memory | 10,000 queued payloads per route and 100 parked batches; the oldest are dropped with a warning. |
| Never crashes the host | Nothing throws into your code. Invalid input and delivery failures are logged (rate-limited) and dropped. |
| Interactions | `begin` / updates queue; each send carries the full accumulated state to `events/track_partial` (latest wins per event id). Updates wait until there's input or output; an interaction finished with neither is still sent, with a warning. An interaction without a `userId` isn't sent until an update sets one. The begin time is kept. `finish` is durable on return. `resumeInteraction(eventId:beganAt:)` needs only the id; its updates are sent without a `userId` (with a warning) and Raindrop keeps the user it has. |
| Tracing | `Span` / `LlmSpan` / `ToolSpan` exported as OTLP JSON batches to `/v1/traces`, linked to the event, user and conversation. Raw `gen_ai.usage.*` only (cost is computed server-side). |
| Apps | Offline storage in Application Support (5 MB / 7 days, excluded from backup, data protection set by `storageProtection`); flush on background under an expiring-activity assertion; retry when the network returns; `PrivacyInfo.xcprivacy` included. |

Hooks: `beforeSend` (edit or drop each payload), `redactPii`, `appGit`, `localWorkshopURL`
(Raindrop Workshop mirror), `transport` (custom HTTP), `logHandler`.

## Conformance

`conformance/` holds the driver for Raindrop's cross-SDK conformance suite (a separate
package, so it never shows up in your dependency graph). CI runs it against a local
fault-injecting server and against real ingest with Query API readback. Known gaps are
ratcheted in [`conformance/failures.txt`](conformance/failures.txt).

## iOS app tests

`examples/RaindropTestApp` runs the SDK inside a SwiftUI app on the iOS simulator: background
flush, kill and relaunch with ingest down, resuming an interaction after relaunch, main-actor
scoped spans, on-device PII redaction, hot-path cost, offline storage and the privacy
manifest. See its README; CI runs it on every change.

## Not yet supported

- Contextual Git detection on Vercel (set `appGit` or the environment variables instead).

## Development

```sh
swift build
swift test
```

With Command Line Tools only (no Xcode), `swift test` can fail intermittently with
"plugin for module 'TestingMacros' not found". That's a toolchain issue: run
`swift build --build-tests` (retry if needed), then `swift test --skip-build`.

## License

MIT
