# RaindropTestApp

A SwiftUI app that uses the SDK the way an app team would (one client, `@MainActor` model,
Swift 6 strict concurrency), plus UI tests that drive it on the iOS simulator while it
sends to a local capture server. Runs in CI (`.github/workflows/ios-app.yml`).

| Test | What it proves |
| --- | --- |
| `testEventDeliversFromTheApp` | Batched `events/track` from an app, with auth, project and SDK headers |
| `testBackgroundingFlushesQueuedEvents` | Going to the background sends what's queued (background loop disabled) |
| `testBackgroundingSendsNothingWithoutLifecycleHandling` | Negative control: the lifecycle hook is what delivers |
| `testUnsentDataSurvivesKillAndRelaunch` | Ingest down → background → app killed → relaunch: everything delivered, byte-identical resend, offline file cleared |
| `testInteractionResumesAfterRelaunch` | An interaction left open when the app was killed is finished by id after relaunch, keeping its begin time |
| `testInteractionWithInlineSubagentFromTheMainActor` | `withSpan` / `withTool` / `inlineSubagent` from the main actor; spans nest in one trace |
| `testPIIIsRedactedBeforeLeavingTheDevice` | `redactPii` scrubs event and span content on device |
| `testHotPathOnTheMainThread` | 1,500 calls (`trackAi` with 2 KB input, signals, identify) on the main thread stay cheap |
| `testOfflineStorageAndPrivacyManifest` | Offline storage in Application Support, excluded from backup; `PrivacyInfo.xcprivacy` bundled |
| `testCompleteProtectionPersistsAcrossRelaunch` | With `storageProtection = .complete`, offline storage still persists across kill + relaunch, and the file carries the configured protection class wherever the OS reports one |
| `testWorkshopMirrorFromTheSimulator` | Workshop mirror over ATS `NSAllowsLocalNetworking` |

CI also builds the library with `APPLICATION_EXTENSION_API_ONLY=YES` (usable in app extensions).

## Run locally (needs Xcode)

```sh
brew install xcodegen
cd examples/RaindropTestApp
python3 capture_server.py --port 8790 &
xcodegen generate
xcodebuild test -project RaindropTestApp.xcodeproj -scheme RaindropTestApp \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Hardware tests not covered here: reading and writing while the device is actually locked (unit
tests simulate an unreadable file), real background time limits, cellular / Low Data Mode, and
Workshop over the LAN.
