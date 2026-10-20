import Foundation

/// A JSON value: used for event properties, identify traits and other free-form data.
///
/// Supports literals, so `["plan": "pro", "seats": 25, "beta": true]` is a valid
/// `[String: JSONValue]`.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The string payload, if this is a `.string`.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The array payload, if this is an `.array`.
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// The object payload, if this is an `.object`.
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Order matters: Bool before numbers, Int64 before Double so 25 stays an integer.
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Minimal JSON writer used for wire payloads.
///
/// Hand-rolled rather than `JSONEncoder` so the output is fully controlled: non-ASCII
/// (including bidi and zero-width characters) is written as raw UTF-8
/// byte-for-byte, `/` is not escaped, and non-finite doubles become `null` instead of
/// throwing on the delivery path.
enum JSONWriter {
    static func data(_ value: JSONValue) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(256)
        write(value, into: &out)
        return Data(out)
    }

    static func write(_ value: JSONValue, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i):
            out.append(contentsOf: Array(String(i).utf8))
        case .double(let d):
            out.append(contentsOf: Array((d.isFinite ? "\(d)" : "null").utf8))
        case .string(let s):
            writeString(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let fields):
            out.append(UInt8(ascii: "{"))
            var first = true
            for (key, item) in fields {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                write(item, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static let hex = Array("0123456789abcdef".utf8)

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: [0x5C, 0x22])
            case UInt8(ascii: "\\"): out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x00..<0x20:
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0xF)]])
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
