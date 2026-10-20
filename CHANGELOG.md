# Changelog

## 0.0.7 (beta)

First beta release.

- `RaindropClient`: `trackAi`, `trackEvent`, `identify`, `trackSignal` (queue only), `flush`,
  `close` (bounded at `flushDeadline`), `validate()`.
- Interactions: `begin`, `update` / `setProperty` / `setInput` / `addAttachments`, `finish`,
  `fail` / `cancel`, `resumeInteraction(eventId:beganAt:)`.
- Tracing: `Span`, `LlmSpan`, `ToolSpan`, `trackTool`, `SpanRef` parents. Spans started
  without `parent:` nest under the task-local `Span.current` when it belongs to the same
  event (`Task {}` and `async let` inherit it; `Task.detached` doesn't; `SpanParent.root`
  opts out). Scoped helpers `withSpan`, `withTool`, `inlineSubagent` and `Span.withCurrent`
  run the closure on the caller's actor, so they work from `@MainActor` code.
- Subagents: `inlineSubagent` runs a subagent as part of the current event. Detached
  subagents (experimental): `Interaction.subagent(name:input:childEventId:)` returns a
  `Codable` `SubagentHandoff` and `RaindropClient.beginSubagent(_:...)` opens the child as its
  own event, linked by `raindrop.handoff.*` attributes. Same attribute names as the
  TypeScript and Python SDKs; no header carrier.
- Delivery: batched `events/track`, latest-wins `events/track_partial`, capped `Retry-After`,
  no retries on non-429 4xx, identical-byte retries, 1M-codepoint truncation.
- `projectId`: trimmed; nil, empty or `"default"` sends no `X-Raindrop-Project-Id` header;
  an invalid slug is ignored with a warning.
- Apps: offline storage (data-protection class set by `storageProtection`; a file that can't
  be read yet, for example while the device is locked, is kept and retried), background
  flush, connectivity retry, privacy manifest.
- `redactPii` (event input/output and span content), `beforeSend`, `appGit`, Raindrop
  Workshop mirror, custom `transport`.
