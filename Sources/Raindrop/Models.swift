import Foundation

/// An AI interaction recorded in one call: user input, model output and metadata.
/// Sent to `POST /v1/events/track`. At least one of `input` / `output` is required.
public struct AiEvent: Sendable {
    public var userId: String
    public var event: String
    public var input: String?
    public var output: String?
    public var model: String?
    public var convoId: String?
    /// Your own event id. When nil the SDK generates a UUID.
    public var eventId: String?
    /// Defaults to the time of the `trackAi` call.
    public var timestamp: Date?
    public var properties: [String: JSONValue]
    public var attachments: [Attachment]
    /// Feature flag name → value, used by Experiments.
    public var featureFlags: [String: String]

    public init(
        userId: String,
        event: String,
        input: String? = nil,
        output: String? = nil,
        model: String? = nil,
        convoId: String? = nil,
        eventId: String? = nil,
        timestamp: Date? = nil,
        properties: [String: JSONValue] = [:],
        attachments: [Attachment] = [],
        featureFlags: [String: String] = [:]
    ) {
        self.userId = userId
        self.event = event
        self.input = input
        self.output = output
        self.model = model
        self.convoId = convoId
        self.eventId = eventId
        self.timestamp = timestamp
        self.properties = properties
        self.attachments = attachments
        self.featureFlags = featureFlags
    }
}

/// A plain (non-AI) analytics event. Sent to `POST /v1/events/track`.
public struct Event: Sendable {
    public var userId: String
    public var event: String
    public var eventId: String?
    public var timestamp: Date?
    public var properties: [String: JSONValue]
    public var attachments: [Attachment]

    public init(
        userId: String,
        event: String,
        eventId: String? = nil,
        timestamp: Date? = nil,
        properties: [String: JSONValue] = [:],
        attachments: [Attachment] = []
    ) {
        self.userId = userId
        self.event = event
        self.eventId = eventId
        self.timestamp = timestamp
        self.properties = properties
        self.attachments = attachments
    }
}

/// Extra context attached to an event: documents, code, images or embeds.
public struct Attachment: Sendable, Equatable {
    public enum Kind: String, Sendable { case text, code, image, iframe }
    public enum Role: String, Sendable { case input, output }

    public var kind: Kind
    public var role: Role
    /// Content, or a URL for images and iframes.
    public var value: String
    public var name: String?
    /// Programming language, for `.code`.
    public var language: String?
    public var attachmentId: String?
    /// Additional keys sent as-is (forward-compatible payload extensions). Never
    /// overrides the typed fields above.
    public var additional: [String: JSONValue]

    public init(
        kind: Kind,
        role: Role,
        value: String,
        name: String? = nil,
        language: String? = nil,
        attachmentId: String? = nil,
        additional: [String: JSONValue] = [:]
    ) {
        self.kind = kind
        self.role = role
        self.value = value
        self.name = name
        self.language = language
        self.attachmentId = attachmentId
        self.additional = additional
    }
}

/// Signal type. `agent` / `agentInternal` are for agent-generated signals.
public enum SignalType: String, Sendable {
    case `default` = "default"
    case feedback
    case edit
    case standard
    case agent
    case agentInternal = "agent_internal"
}

/// Signal sentiment. Applied when Raindrop first sees a signal name.
public enum Sentiment: String, Sendable {
    case positive = "POSITIVE"
    case negative = "NEGATIVE"
}

/// A quality signal (thumbs up/down, edit, …) on an event you already sent.
/// Sent to `POST /v1/signals/track`.
public struct Signal: Sendable {
    public var eventId: String
    public var name: String
    public var type: SignalType
    public var sentiment: Sentiment?
    public var timestamp: Date?
    public var properties: [String: JSONValue]
    public var attachmentId: String?
    /// Merged into `properties.comment` (as the other SDKs do).
    public var comment: String?
    /// Merged into `properties.after`, for edit signals.
    public var after: String?

    public init(
        eventId: String,
        name: String,
        type: SignalType = .default,
        sentiment: Sentiment? = nil,
        timestamp: Date? = nil,
        properties: [String: JSONValue] = [:],
        attachmentId: String? = nil,
        comment: String? = nil,
        after: String? = nil
    ) {
        self.eventId = eventId
        self.name = name
        self.type = type
        self.sentiment = sentiment
        self.timestamp = timestamp
        self.properties = properties
        self.attachmentId = attachmentId
        self.comment = comment
        self.after = after
    }
}

/// Outcome of `flush()` / `close()`.
public struct FlushResult: Sendable, Equatable {
    /// Payloads accepted by ingest (2xx) during this call.
    public var delivered: Int = 0
    /// Payloads permanently rejected (non-429 4xx) or dropped by `beforeSend`.
    public var dropped: Int = 0
    /// Payloads still queued or parked for a later retry.
    public var pending: Int = 0
    /// The call's deadline expired before everything was attempted.
    public var timedOut: Bool = false
    /// Payloads given up on: cut off at the deadline while in flight (not resent, since
    /// they may already have reached ingest), or abandoned after repeated failed sends.
    /// Unlike `dropped`, these were never delivered.
    public var undelivered: Int = 0

    /// True when everything was handed to ingest and nothing is left to send.
    public var isComplete: Bool { pending == 0 && !timedOut && undelivered == 0 }

    public init(delivered: Int = 0, dropped: Int = 0, pending: Int = 0, timedOut: Bool = false,
                undelivered: Int = 0) {
        self.delivered = delivered
        self.dropped = dropped
        self.pending = pending
        self.timedOut = timedOut
        self.undelivered = undelivered
    }
}

/// Errors from `validate()`.
public enum RaindropError: Error, Sendable, Equatable {
    /// No write key configured; the client is a no-op.
    case disabled
    /// 401: missing, unknown or expired write key.
    case unauthorized
    /// 403: the project slug is archived or over the org's project limit.
    case forbiddenProject
    /// 400: malformed project slug or request.
    case badRequest
    /// Any other HTTP status.
    case unexpectedStatus(Int)
    /// The request didn't complete.
    case transport(String)
}
