# Changelog

## 0.0.8 (beta)

- Detached subagents: `SubagentHandoff.headers` writes the handoff carrier
  (`x-raindrop-handoff`, `baggage`, and `traceparent` when the ids are W3C-shaped) and
  `SubagentHandoff(headers:)` / `RaindropClient.beginSubagent(headers:...)` read one written by
  any Raindrop SDK. A child with no readable carrier still reports, as an unlinked event.
  `SubagentHandoff` gains `traceId` (the dispatch span's trace).
- `trackTool(endTime:)`: a start time plus an end time instead of a duration (the end wins
  when both are given).
- Span start and end times keep millisecond and microsecond values exactly.
- Delivery: 408 is retried like 429 and 5xx. A 2xx response that lists `rejected` items or
  `warnings` is logged as a warning.
- Interactions: one begun without a `userId` isn't sent until an update sets one. Updates for a
  resumed interaction without a `userId` are sent with a warning. Finishing with no input or
  output still sends the event; the warning no longer says it is dropped, and a resumed
  interaction doesn't warn.
- Flush deadline: a request still in flight when the `flush()` / `close()` deadline passes is
  dropped instead of resent, since it may already have reached the server. Payloads not yet
  sent, or waiting on a retry, stay queued. `FlushResult.undelivered` counts payloads given up
  on, and `isComplete` is false when any were. `flush()` and `close()` log a warning when they
  return with anything not delivered; `close()` says whether leftovers were saved to offline
  storage or dropped.

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
