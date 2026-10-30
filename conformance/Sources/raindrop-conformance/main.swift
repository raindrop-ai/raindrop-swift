// Thin driver mapping the conformance suite's step vocabulary onto the PUBLIC Raindrop
// Swift API (driver protocol major 1).
//
//   raindrop-conformance --describe        → JSON handshake on stdout, exit 0
//   raindrop-conformance  < steps.json     → runs steps, one {"step":n,"ms":x} line each
//
// Rules: public API only; unmappable args refuse loudly (`unsupported:<step>`, exit 3);
// JSON null on an optional top-level arg ≡ omitted.
import Foundation
import Raindrop

let driverVersion = "0.3.0"

let capabilities = [
    "events.track",
    "events.track_ai",
    "events.track_partial",
    "events.feature_flags",
    "app_git.config",
    "app_git.environment",
    "identify",
    "signal",
    "timing.wait",
    "multi_client",
    "events.resume",
    "events.optional_user_id",
    "traces.retroactive_span",
    "traces.span_parent",
    "subagents.detached_dispatch",
    "subagents.detached_child",
    "privacy.redact_pii",
    "logs.capture",
]

// Plain string arrays: the suite's coverage tooling reads these from source.
let notApplicable = ["events.track_ai_partial", "wrapper.capture"]

let notApplicableReasons: [String: String] = [
    "wrapper.capture":
        "raindrop-swift is a direct-call core SDK (trackAi/trackEvent/identify/trackSignal), not a framework "
        + "wrapper; no callback/wrapped-invocation/middleware capture path exists by design.",
    "events.track_ai_partial":
        "trackAi always delivers through the batched events/track route; the alternate "
        + "partial-routing declaration cannot apply to it.",
]

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func refuse(_ step: String, _ why: String) -> Never {
    FileHandle.standardError.write(Data("refusing \(step): \(why)\n".utf8))
    emit("unsupported:\(step)")
    exit(3)
}

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data("driver error: \(why)\n".utf8))
    exit(1)
}

if CommandLine.arguments.contains("--describe") {
    let describe: JSONValue = [
        "sdk_name": "raindrop-swift",
        "sdk_version": .string(RaindropSDK.version),
        "driver_version": .string(driverVersion),
        "protocol": 1,
        "capabilities": .array(capabilities.map { .string($0) }),
        "not_applicable": .array(notApplicable.map { .string($0) }),
        "not_applicable_reasons": .object(notApplicableReasons.mapValues { .string($0) }),
    ]
    let data = try! JSONEncoder().encode(describe)
    emit(String(decoding: data, as: UTF8.self))
    exit(0)
}

// MARK: SDK log capture (CONTRACT 14)

/// SDK log records as JSON lines for the runner, through the SDK's public log hook.
let harnessLog: (@Sendable (LogLevel, String) -> Void)? = {
    guard let path = ProcessInfo.processInfo.environment["RAINDROP_HARNESS_LOG"], !path.isEmpty else { return nil }
    let lock = NSLock()
    return { level, message in
        let record: JSONValue = ["level": .string(level == .warning ? "warn" : "debug"), "message": .string(message)]
        guard let data = try? JSONEncoder().encode(record) else { return }
        lock.withLock {
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }
}()

// MARK: Arg helpers

struct Args {
    let step: String
    let raw: [String: JSONValue]

    init(step: String, raw: [String: JSONValue], allowed: Set<String>) {
        self.step = step
        // null ≡ omitted
        self.raw = raw.filter { $0.value != .null }
        let unknown = Set(self.raw.keys).subtracting(allowed.union(["client", "max_ms"]))
        if !unknown.isEmpty { refuse(step, "args not mappable onto the public API: \(unknown.sorted())") }
    }

    var client: String { string("client") ?? "default" }

    func string(_ key: String) -> String? {
        guard let v = raw[key] else { return nil }
        guard case .string(let s) = v else { fail("\(step).\(key) must be a string") }
        return s
    }

    func required(_ key: String) -> String {
        guard let s = string(key) else { fail("\(step) requires \(key)") }
        return s
    }

    func json(_ key: String) -> JSONValue? { raw[key] }

    func int(_ key: String) -> Int64? {
        switch raw[key] {
        case nil: return nil
        case .int(let i)?: return i
        case .double(let d)? where d.rounded() == d: return Int64(d)
        default: fail("\(step).\(key) must be an integer")
        }
    }

    func object(_ key: String) -> [String: JSONValue]? {
        guard let v = raw[key] else { return nil }
        guard case .object(let o) = v else { fail("\(step).\(key) must be an object") }
        return o
    }

    func date(_ key: String) -> Date? {
        guard let s = string(key) else { return nil }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? withFraction.parse(s) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(s) { return d }
        refuse(step, "\(key) '\(s)' is not ISO-8601; the public API takes a Date")
    }

    func stringMap(_ key: String) -> [String: String] {
        guard let o = object(key) else { return [:] }
        return o.mapValues { v in
            guard case .string(let s) = v else { fail("\(step).\(key) values must be strings") }
            return s
        }
    }

    func attachments() -> [Attachment] {
        guard let v = raw["attachments"] else { return [] }
        guard case .array(let items) = v else { fail("\(step).attachments must be an array") }
        return items.map { item in
            guard var o = item.objectValue,
                  let kind = o.removeValue(forKey: "type")?.stringValue.flatMap(Attachment.Kind.init(rawValue:)),
                  let role = o.removeValue(forKey: "role")?.stringValue.flatMap(Attachment.Role.init(rawValue:)),
                  let value = o.removeValue(forKey: "value")?.stringValue
            else { fail("\(step).attachments item needs valid type/role/value") }
            return Attachment(
                kind: kind, role: role, value: value,
                name: o.removeValue(forKey: "name")?.stringValue,
                language: o.removeValue(forKey: "language")?.stringValue,
                attachmentId: o.removeValue(forKey: "attachment_id")?.stringValue,
                additional: o)
        }
    }
}

// MARK: Clients

final class Clients: @unchecked Sendable {
    private var byHandle: [String: RaindropClient] = [:]
    private var bindings: [String: Interaction] = [:]   // one open interaction per client
    /// Carriers produced by dispatch_subagent, by child event id (shared by every client).
    var carriers: [String: [String: String]] = [:]

    func bind(_ a: Args, _ i: Interaction) {
        guard bindings[a.client] == nil else { fail("client \(a.client) already has an open interaction") }
        bindings[a.client] = i
    }

    func bound(_ a: Args) -> Interaction {
        guard let i = bindings[a.client] else { fail("\(a.step) without an open begin on client \(a.client)") }
        return i
    }

    func unbind(_ a: Args) { bindings[a.client] = nil }

    func initialize(_ a: Args) {
        let handle = a.client
        guard byHandle[handle] == nil else { fail("client \(handle) initialized twice") }
        let env = ProcessInfo.processInfo.environment
        let index = byHandle.count
        let keyVar = index == 0 ? "RAINDROP_WRITE_KEY" : "RAINDROP_WRITE_KEY_\(index + 1)"
        let sink = (env["RAINDROP_SINK_URL"] ?? "https://api.raindrop.ai").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let endpoint = URL(string: sink + "/v1/") else { fail("bad RAINDROP_SINK_URL") }

        var config = RaindropConfiguration(
            writeKey: env[keyVar] ?? env["RAINDROP_WRITE_KEY"],
            projectId: a.string("project") ?? env["RAINDROP_PROJECT_ID"])
        config.endpoint = endpoint
        config.appGit = appGit(a)
        config.debug = env["RAINDROP_DEBUG"] == "1"
        if let raw = a.raw["redact_pii"] {
            guard raw == .bool(true) else { fail("init.redact_pii must be true") }
            config.redactPii = true
        }
        config.logHandler = harnessLog
        byHandle[handle] = RaindropClient(configuration: config)
    }

    /// Maps init.app_git onto the public AppGitConfig. The SDK has no automatic discovery,
    /// so `auto_detect: false` is already true of it; fields needing discovery are refused.
    func appGit(_ a: Args) -> AppGitConfig? {
        guard let raw = a.raw["app_git"] else { return AppGitConfig() }
        if raw == .bool(false) { return nil }
        guard let o = raw.objectValue else { fail("init.app_git must be false or an object") }
        for key in ["detect_branch", "source_directory"] where o[key] != nil {
            refuse("init", "app_git.\(key) needs automatic Git discovery, which raindrop-swift doesn't do")
        }
        if o["auto_detect"] == .bool(true) {
            refuse("init", "app_git.auto_detect: true needs automatic discovery, which raindrop-swift doesn't do")
        }
        var dirty: Bool?
        if case .bool(let b)? = o["commit_dirty"] { dirty = b }
        return AppGitConfig(commitSha: o["commit_sha"]?.stringValue, commitDirty: dirty, branch: o["branch"]?.stringValue)
    }

    func get(_ a: Args) -> RaindropClient {
        guard let c = byHandle[a.client] else { fail("client \(a.client) used before init") }
        return c
    }
}

// MARK: Steps

let trackAiArgs: Set<String> = ["user_id", "event", "input", "output", "event_id", "timestamp", "model",
                                "convo_id", "properties", "attachments", "feature_flags"]
let trackArgs: Set<String> = ["user_id", "event", "event_id", "timestamp", "properties", "attachments"]
let signalArgs: Set<String> = ["event_id", "name", "signal_type", "timestamp", "properties", "attachment_id",
                               "comment", "after", "sentiment"]

func run(_ name: String, _ raw: [String: JSONValue], _ clients: Clients) async {
    switch name {
    case "init":
        clients.initialize(Args(step: name, raw: raw, allowed: ["project", "app_git", "redact_pii"]))

    case "track_ai":
        let a = Args(step: name, raw: raw, allowed: trackAiArgs)
        clients.get(a).trackAi(AiEvent(
            userId: a.string("user_id") ?? "", event: a.required("event"),
            input: a.string("input"), output: a.string("output"), model: a.string("model"),
            convoId: a.string("convo_id"), eventId: a.string("event_id"), timestamp: a.date("timestamp"),
            properties: a.object("properties") ?? [:], attachments: a.attachments(),
            featureFlags: a.stringMap("feature_flags")))

    case "track":
        let a = Args(step: name, raw: raw, allowed: trackArgs)
        clients.get(a).trackEvent(Event(
            userId: a.string("user_id") ?? "", event: a.required("event"), eventId: a.string("event_id"),
            timestamp: a.date("timestamp"), properties: a.object("properties") ?? [:],
            attachments: a.attachments()))

    case "identify":
        let a = Args(step: name, raw: raw, allowed: ["user_id", "traits"])
        clients.get(a).identify(userId: a.required("user_id"), traits: a.object("traits") ?? [:])

    case "signal":
        let a = Args(step: name, raw: raw, allowed: signalArgs)
        var type = SignalType.default
        if let t = a.string("signal_type") {
            guard let parsed = SignalType(rawValue: t) else { refuse(name, "unknown signal_type \(t)") }
            type = parsed
        }
        var sentiment: Sentiment?
        if let s = a.string("sentiment") {
            guard let parsed = Sentiment(rawValue: s) else { refuse(name, "unknown sentiment \(s)") }
            sentiment = parsed
        }
        clients.get(a).trackSignal(Signal(
            eventId: a.required("event_id"), name: a.required("name"), type: type, sentiment: sentiment,
            timestamp: a.date("timestamp"), properties: a.object("properties") ?? [:],
            attachmentId: a.string("attachment_id"), comment: a.string("comment"), after: a.string("after")))

    case "begin":
        let a = Args(step: name, raw: raw, allowed: ["user_id", "event", "event_id", "timestamp", "input", "model",
                                                     "convo_id", "properties", "attachments"])
        let ix = clients.get(a).begin(BeginOptions(
            userId: a.string("user_id") ?? "", event: a.required("event"), input: a.string("input"),
            model: a.string("model"), convoId: a.string("convo_id"), eventId: a.string("event_id"),
            timestamp: a.date("timestamp"), properties: a.object("properties") ?? [:], attachments: a.attachments()))
        clients.bind(a, ix)

    case "patch":
        let a = Args(step: name, raw: raw, allowed: ["timestamp", "user_id", "event", "input", "output", "model",
                                                     "convo_id", "properties", "attachments"])
        clients.bound(a).update(InteractionUpdate(
            userId: a.string("user_id"), event: a.string("event"), input: a.string("input"), output: a.string("output"),
            model: a.string("model"), convoId: a.string("convo_id"), timestamp: a.date("timestamp"),
            properties: a.object("properties") ?? [:], attachments: a.attachments()))

    case "finish":
        let a = Args(step: name, raw: raw, allowed: ["timestamp", "output", "model", "properties", "attachments"])
        await clients.bound(a).finish(output: a.string("output"), model: a.string("model"),
                                      properties: a.object("properties") ?? [:], attachments: a.attachments(),
                                      timestamp: a.date("timestamp"))
        clients.unbind(a)

    case "resume":
        // CONTRACT 9.2: bind to an event begun elsewhere by id. Nothing is sent now; identity
        // the step supplies rides on later updates, and omitted identity is never defaulted.
        let a = Args(step: name, raw: raw, allowed: ["event_id", "user_id", "event", "convo_id"])
        let ix = clients.get(a).resumeInteraction(eventId: a.required("event_id"))
        clients.bind(a, ix)
        if a.string("user_id") != nil || a.string("event") != nil || a.string("convo_id") != nil {
            ix.update(InteractionUpdate(userId: a.string("user_id"), event: a.string("event"),
                                        convoId: a.string("convo_id")))
        }

    case "track_tool":
        // CONTRACT 12: a tool span recorded after the fact on the open event.
        let a = Args(step: name, raw: raw, allowed: ["name", "input", "output", "error", "start_time",
                                                     "duration_ms", "end_time", "parent"])
        var parent: SpanParent?
        if let p = a.object("parent") {
            guard let trace = p["trace_id"]?.stringValue, let span = p["span_id"]?.stringValue else {
                fail("track_tool.parent needs trace_id and span_id")
            }
            parent = .ref(SpanRef(traceId: trace, spanId: span))
        }
        clients.bound(a).trackTool(a.required("name"), input: a.json("input"), output: a.json("output"),
                                   error: a.string("error"), duration: a.int("duration_ms").map { .milliseconds($0) },
                                   startTime: a.date("start_time"), endTime: a.date("end_time"), parent: parent)

    case "dispatch_subagent":
        // CONTRACT 13.1: a dispatch span on the open event, plus the header carrier.
        let a = Args(step: name, raw: raw, allowed: ["name", "child_event_id", "input"])
        let handoff = clients.bound(a).subagent(name: a.required("name"), input: a.json("input"),
                                                childEventId: a.required("child_event_id"))
        clients.carriers[handoff.childEventId] = handoff.headers

    case "run_subagent":
        // CONTRACT 13.2: the child reports as its own event from the carrier.
        let a = Args(step: name, raw: raw, allowed: ["output", "carrier_from", "headers", "user_id", "tool_name"])
        let headers: [String: String]
        if let source = a.string("carrier_from") {
            guard let carrier = clients.carriers[source] else { fail("no carrier was dispatched for \(source)") }
            headers = carrier
        } else {
            headers = a.stringMap("headers")
        }
        let child = clients.get(a).beginSubagent(headers: headers, userId: a.string("user_id"))
        if let tool = a.string("tool_name") {
            // The child's work: one tool span while its run is open, carrying the link back.
            child.trackTool(tool, duration: .milliseconds(1))
        }
        await child.finish(output: a.required("output"))

    case "flush":
        let a = Args(step: name, raw: raw, allowed: [])
        await clients.get(a).flush()

    case "close":
        let a = Args(step: name, raw: raw, allowed: [])
        await clients.get(a).close()

    case "wait":
        let a = Args(step: name, raw: raw, allowed: ["ms"])
        let ms: Double
        switch a.raw["ms"] {
        case .int(let i)?: ms = Double(i)
        case .double(let d)?: ms = d
        default: fail("wait requires numeric ms")
        }
        try? await Task.sleep(for: .milliseconds(Int64(ms)))

    default:
        refuse(name, "unknown step")
    }
}

// MARK: Main

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let steps = try? JSONDecoder().decode([[String: JSONValue]].self, from: input) else {
    fail("stdin is not a JSON array of single-key step objects")
}
let clients = Clients()
let clock = ContinuousClock()
for (index, step) in steps.enumerated() {
    guard step.count == 1, let (name, value) = step.first else { fail("step \(index) must have exactly one key") }
    let args = value.objectValue ?? [:]
    let elapsed = await clock.measure { await run(name, args, clients) }
    let c = elapsed.components
    let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    emit("{\"step\":\(index),\"ms\":\(ms)}")
}
exit(0)
