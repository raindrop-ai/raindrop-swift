import Foundation

/// A payload about to be sent, handed to `beforeSend`.
public struct RaindropPayload: Sendable {
    /// Ingest route without the `/v1/` prefix: `events/track`, `users/identify` or `signals/track`.
    public let route: String
    /// One event / identify / signal object, exactly as it will be serialized.
    public var body: [String: JSONValue]
}

public enum LogLevel: String, Sendable { case debug, warning }

/// iOS data-protection class for the offline storage file (`storageDirectory`).
public enum StorageProtection: Sendable, Equatable {
    /// Readable after the first unlock since restart (default). Background flushes and
    /// relaunches work while the device is locked again.
    case completeUntilFirstUserAuthentication
    /// Can be created while locked, but not reopened until unlocked.
    case completeUnlessOpen
    /// Readable and writable only while the device is unlocked. While it's locked, unsent
    /// data stays in memory and is saved at the next opportunity after unlock; saved data
    /// from an earlier run is read back once the device is unlocked. If the app is killed
    /// while locked, data queued since the last save is lost.
    case complete
    /// No data protection.
    case none
}

/// Client configuration. Only `writeKey` is required for normal use.
public struct RaindropConfiguration: Sendable {
    /// Raindrop write key. When nil or empty the client is a no-op: nothing is queued
    /// or sent, and one warning is logged.
    public var writeKey: String?
    /// Project slug (`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`), sent as `X-Raindrop-Project-Id`.
    /// When nil, empty/whitespace or `"default"`, no header is sent and data goes to the org's
    /// default (Production) project. Surrounding whitespace and newlines are trimmed. A value
    /// that isn't a valid slug is ignored with a warning (the default project is used),
    /// matching the other Raindrop SDKs; sending it would make ingest reject every request.
    public var projectId: String?
    /// Ingest base URL; routes are appended (e.g. `<endpoint>events/track`).
    public var endpoint: URL = URL(string: "https://api.raindrop.ai/v1/")!

    /// How often queued payloads are sent in the background.
    public var flushInterval: Duration = .seconds(1)
    /// Most payloads per request.
    public var maxBatchSize: Int = 100
    /// Soft cap on a request body, in bytes. A single larger payload is still sent alone.
    public var maxBatchBytes: Int = 900_000
    /// Most payloads held in memory per route; the oldest are dropped (with a warning) beyond it.
    public var maxQueueSize: Int = 10_000

    /// Per-request timeout. A request that times out is not resent within the same
    /// `flush` / `close` call; it is retried with identical bytes on a later cycle.
    public var requestTimeout: Duration = .seconds(2)
    /// Deadline for `flush()` and `close()` (default 10 s).
    public var flushDeadline: Duration = .seconds(10)
    /// Upper bound on an honoured `Retry-After` (default 30 s).
    public var maxRetryAfter: Duration = .seconds(30)
    /// Attempts per batch within one send cycle (429 / 5xx).
    public var maxAttempts: Int = 4

    /// Cap on `input` / `output`, in Unicode codepoints.
    public var maxTextFieldChars: Int = 1_000_000

    /// Redact common PII (emails, phone numbers, card numbers, SSNs, street addresses,
    /// passwords/credentials) before sending, using the same patterns and placeholders as
    /// the TypeScript SDK's `redactPii`. Applies to AI `input` / `output` on events and
    /// interactions, and to span content: prompts and messages (`ai.prompt*`,
    /// `gen_ai.prompt.*.content`), responses (`ai.response.text`,
    /// `gen_ai.completion.*.content`), tool input/output (`traceloop.entity.*`) and span
    /// error messages. Ids, names, properties and other attributes are left as they are.
    /// Runs before `beforeSend`. Off by default.
    public var redactPii: Bool = false

    /// Application identity attached to events and spans as `raindrop.app.commit_sha`,
    /// `raindrop.app.commit_dirty` and `raindrop.app.branch` (caller properties win).
    /// Explicit values here take precedence over the `RAINDROP_COMMIT_SHA`,
    /// `RAINDROP_COMMIT_DIRTY` and `RAINDROP_BRANCH` environment variables. Set to nil to
    /// disable app identity entirely. In iOS apps, inject build values here; apps have
    /// no process environment.
    public var appGit: AppGitConfig? = AppGitConfig()

    /// Export spans to `/v1/traces`. When false, span APIs return inert spans.
    public var tracingEnabled: Bool = true

    /// Where unsent payloads are saved so they survive suspension, termination and relaunch.
    /// Defaults to Application Support/Raindrop on iOS, tvOS, watchOS and visionOS, and to
    /// nil (memory only) on macOS and Linux. Set nil to disable.
    public var storageDirectory: URL? = RaindropConfiguration.defaultStorageDirectory

    /// Data protection for the offline storage file. Ignored where the OS has no data
    /// protection (Linux; macOS without it enabled). Choose `.complete` if your security
    /// policy requires data to be unreadable while the device is locked.
    public var storageProtection: StorageProtection = .completeUntilFirstUserAuthentication

    /// On iOS, tvOS, watchOS and visionOS: when the app goes to the background, send what's
    /// queued (within the time the system allows) and save the rest to `storageDirectory`.
    /// Also flushes when network connectivity returns. Default true.
    public var handleAppLifecycle: Bool = true

    /// Mirror every request to a local Raindrop Workshop daemon (best effort, one attempt).
    /// When nil: `RAINDROP_LOCAL_DEBUGGER` (URL), then `RAINDROP_WORKSHOP` (URL, or
    /// `1`/`true` for `http://localhost:5899/v1/`, `0`/`false` to disable). With a Workshop
    /// URL and no write key, the client runs in Workshop-only mode.
    public var localWorkshopURL: URL?

    /// Verbose logging.
    public var debug: Bool = false
    /// Last chance to edit or drop (return nil) each payload. Runs off the caller's
    /// thread, just before serialization.
    public var beforeSend: (@Sendable (RaindropPayload) -> RaindropPayload?)?
    /// Custom HTTP transport (tests, proxies). Defaults to a dedicated `URLSession`.
    public var transport: (any HTTPTransport)?
    /// Log sink. Defaults to stderr. Warnings are always emitted; debug lines only when `debug`.
    public var logHandler: (@Sendable (LogLevel, String) -> Void)?

    public init(writeKey: String?, projectId: String? = nil) {
        self.writeKey = writeKey
        self.projectId = projectId
    }

    var isEnabled: Bool { !(writeKey ?? "").isEmpty }

    public static var defaultStorageDirectory: URL? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return Storage.defaultDirectory()
        #else
        return nil
        #endif
    }

    static let defaultWorkshopURL = URL(string: "http://localhost:5899/v1/")!

    /// Same precedence as the TypeScript SDK's Workshop resolution (minus hostname auto-detect).
    func resolvedWorkshopURL(environment: [String: String]) -> URL? {
        if let url = localWorkshopURL { return Self.normalized(url) }
        if let raw = environment["RAINDROP_LOCAL_DEBUGGER"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            return URL(string: raw).map(Self.normalized)
        }
        if let raw = environment["RAINDROP_WORKSHOP"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let lower = raw.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: raw).map(Self.normalized) }
            if ["1", "true", "yes", "on"].contains(lower) { return Self.defaultWorkshopURL }
        }
        return nil
    }

    /// Ensures a trailing `/v1/` so routes append correctly.
    static func normalized(_ url: URL) -> URL {
        var s = url.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        if !s.hasSuffix("/v1/") { s += "v1/" }
        return URL(string: s) ?? url
    }

    /// The `X-Raindrop-Project-Id` value to send, or nil for the org's default project.
    var projectHeader: String? {
        guard let p = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty,
              p != "default", Self.isValidProjectSlug(p) else { return nil }
        return p
    }

    /// A project id was given but can't be used (not a valid slug).
    var hasInvalidProjectId: Bool {
        guard let p = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return false }
        return !Self.isValidProjectSlug(p)
    }

    /// Same slug pattern Raindrop ingest and the other Raindrop SDKs accept.
    static func isValidProjectSlug(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard (1...63).contains(bytes.count) else { return false }
        func alnum(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) }
        guard alnum(bytes.first!), alnum(bytes.last!) else { return false }
        return bytes.allSatisfy { alnum($0) || $0 == 0x2D }
    }
}
