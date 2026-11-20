import Foundation

/// Where a value passed to `RaindropConfiguration.mask` comes from.
public struct MaskContext: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// An event (`trackAi`, `trackEvent`, interactions).
        case event
        /// A signal (`trackSignal`).
        case signal
        /// User traits (`identify`).
        case identify
        /// A trace span.
        case span
    }

    /// The payload kind.
    public let kind: Kind
    /// The wire field: `ai_data.input`, `ai_data.output`, `properties` or `attachments` for an
    /// event; `properties` for a signal (its `comment` and `after` included); `traits` for an
    /// identify; for a span, the content attribute's name or `status.message`.
    public let field: String

    public init(kind: Kind, field: String) {
        self.kind = kind
        self.field = field
    }
}

/// A masking function: receives one field's value and returns the value to send.
///
/// Strings (`ai_data.input`, `ai_data.output`, span content) arrive as `.string` and must come
/// back as `.string`; `properties` and `traits` arrive as `.object` and must come back as
/// `.object`; `attachments` arrive as `.array` and must come back as `.array`.
/// If it throws or returns another type, the field is sent as `"<MASK FAILED>"` (an object as
/// `{"error": "<MASK FAILED>"}`, attachments as `[]`); the payload is still sent and a warning
/// names only the error's type.
public typealias RaindropMask = @Sendable (JSONValue, MaskContext) throws -> JSONValue

/// Applies the caller's mask with the fail-closed rules.
struct Masker: Sendable {
    static let failed = "<MASK FAILED>"

    let mask: RaindropMask
    let log: Log

    private enum Shape { case string, object, array }

    private func warn(_ context: MaskContext, _ reason: String) {
        log.warn("mask.failed", "mask function failed on \(context.kind.rawValue) \(context.field) (\(reason)); sending \(Self.failed) in its place")
    }

    private func run(_ value: JSONValue, _ shape: Shape, _ context: MaskContext) -> JSONValue {
        do {
            let result = try mask(value, context)
            switch (shape, result) {
            case (.string, .string), (.object, .object), (.array, .array):
                return result
            default:
                let expected = shape == .string ? "a string" : shape == .object ? "an object" : "an array"
                warn(context, "it returned a value that is not \(expected)")
            }
        } catch {
            // The message can quote the content being masked: only the error's type is logged.
            warn(context, String(describing: type(of: error)))
        }
        switch shape {
        case .string: return .string(Self.failed)
        case .object: return ["error": .string(Self.failed)]
        case .array: return []
        }
    }

    func string(_ value: String, _ context: MaskContext) -> String {
        run(.string(value), .string, context).stringValue ?? Self.failed
    }

    func object(_ value: [String: JSONValue], _ context: MaskContext) -> [String: JSONValue] {
        run(.object(value), .object, context).objectValue ?? ["error": .string(Self.failed)]
    }

    func array(_ value: [JSONValue], _ context: MaskContext) -> [JSONValue] {
        run(.array(value), .array, context).arrayValue ?? []
    }

    /// Properties the SDK sets itself: never passed to the mask, kept as they are.
    static func isSDKProperty(_ key: String) -> Bool {
        key == "$context" || key.hasPrefix("raindrop.app.")
    }

    /// An event, signal or identify payload with its content fields passed through the mask.
    /// Identity and routing fields are never passed.
    func payload(_ body: [String: JSONValue], kind: MaskContext.Kind) -> [String: JSONValue] {
        var body = body
        switch kind {
        case .event:
            if var ai = body["ai_data"]?.objectValue {
                for key in ["input", "output"] {
                    if let text = ai[key]?.stringValue {
                        ai[key] = .string(string(text, MaskContext(kind: .event, field: "ai_data.\(key)")))
                    }
                }
                body["ai_data"] = .object(ai)
            }
            if let properties = body["properties"]?.objectValue {
                let own = properties.filter { !Self.isSDKProperty($0.key) }
                let sdk = properties.filter { Self.isSDKProperty($0.key) }
                let masked = object(own, MaskContext(kind: .event, field: "properties"))
                body["properties"] = .object(masked.merging(sdk) { _, sdk in sdk })
            }
            if let attachments = body["attachments"]?.arrayValue {
                body["attachments"] = .array(array(attachments, MaskContext(kind: .event, field: "attachments")))
            }
        case .signal:
            if let properties = body["properties"]?.objectValue {
                body["properties"] = .object(object(properties, MaskContext(kind: .signal, field: "properties")))
            }
        case .identify:
            if let traits = body["traits"]?.objectValue {
                body["traits"] = .object(object(traits, MaskContext(kind: .identify, field: "traits")))
            }
        case .span:
            break
        }
        return body
    }
}
