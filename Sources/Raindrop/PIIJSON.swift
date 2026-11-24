import Foundation

/// The JSON pass of the shared redaction rules. Event input/output that looks like JSON, and
/// JSON-valued span content, is redacted one string token at a time:
///
/// - Every complete string token is decoded (so an escaped `jane\u0040example.com` is
///   caught), gets the rules and, only if that changed it, is re-encoded.
/// - A string or number value whose key (lowercased, without whitespace, `_`, `.` and `-`) is
///   a cue key (`dob`, `mrn`, ...) is redacted as if its cue came first; a number so
///   redacted becomes a JSON string.
/// - In JSON that parses, keys, other numbers, structure and whitespace stay byte for byte.
///   In JSON that does not parse (cut by a cap, malformed), a quoted "key" may just be quoted
///   text, so keys get the rules too; an unterminated trailing string is decoded, redacted
///   and re-encoded without a closing quote; and the text between strings has its escapes
///   decoded before the rules. Escapes that aren't well formed are kept as written.
///
/// Never throws and never fails: it works on any text.
enum PIIJSON {
    typealias Scalars = [Unicode.Scalar]

    private static let cues: [String: String] = {
        var out: [String: String] = [:]
        for (cue, keys) in PIIRedactor.jsonCueKeys { for key in keys { out[normalizeCueKey(key)] = cue } }
        return out
    }()

    static func normalizeCueKey(_ key: String) -> String {
        String(String.UnicodeScalarView(key.lowercased().unicodeScalars.filter {
            !$0.properties.isWhitespace && $0 != "_" && $0 != "." && $0 != "-"
        }))
    }

    /// After whitespace it starts with `{"`, or with `[` then `"`, `{` or `[`; or it is a
    /// complete JSON object or array.
    static func looksLikeJSON(_ text: String) -> Bool {
        let s = Array(text.unicodeScalars)
        var i = skipWhitespace(s, 0)
        if i < s.count, s[i] == "{" {
            i = skipWhitespace(s, i + 1)
            if i < s.count, s[i] == "\"" { return true }
        } else if i < s.count, s[i] == "[" {
            i = skipWhitespace(s, i + 1)
            if i < s.count, s[i] == "\"" || s[i] == "{" || s[i] == "[" { return true }
        }
        return isCompleteContainer(text)
    }

    /// Whether `text` parses as one JSON object or array.
    static func isCompleteContainer(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first(where: { !$0.properties.isWhitespace }), first == "{" || first == "[" else {
            return false
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return false }
        return parsed is [Any] || parsed is [String: Any]
    }

    /// Event input or output: the JSON pass when the text looks like JSON, then the rules over
    /// the whole text (so a key or bare number that is itself PII is still redacted, even if
    /// the result is then not valid JSON). Nil only if the rules are unavailable.
    static func redactEventText(_ text: String) -> String? {
        let passed = looksLikeJSON(text) ? pass(text) : text
        return passed.flatMap(PIIRedactor.redactIfAvailable)
    }

    /// Span content: JSON-valued content (starts with `{`, `[` or `"`) gets the JSON pass only;
    /// other text gets the rules. Nil only if the rules are unavailable.
    static func redactSpanText(_ text: String) -> String? {
        let first = text.unicodeScalars.first { !$0.properties.isWhitespace }
        if first == "{" || first == "[" || first == "\"" { return pass(text) }
        return PIIRedactor.redactIfAvailable(text)
    }

    // MARK: The pass

    /// Nil only if the rules are unavailable.
    static func pass(_ text: String) -> String? {
        guard let rules = PIIRedactor.compiled else { return nil }
        let complete = isCompleteContainer(text)
        let s = Array(text.unicodeScalars)
        var out = ""
        var looseStart = 0

        func flush(_ end: Int) {
            guard end > looseStart else { return }
            let loose = string(s[looseStart..<end])
            out += complete ? loose : redactLoose(loose, rules)
        }

        var i = s.firstIndex(of: "\"", from: 0)
        while let open = i {
            let end = stringTokenEnd(s, open)
            if end < 0 { break }   // an unterminated string runs to the end: it joins the loose text
            flush(open)
            let after = skipWhitespace(s, end)
            let token = string(s[open..<end])
            let isKey = after < s.count && s[after] == ":"
            if isKey, let cue = cues[normalizeCueKey(decodeEscapes(string(s[(open + 1)..<(end - 1)])))] {
                let start = skipWhitespace(s, after + 1)
                var valueEnd = start
                var replacement: String?
                if start < s.count, s[start] == "\"" {
                    valueEnd = stringTokenEnd(s, start)
                    if valueEnd < 0 {
                        valueEnd = s.count
                        replacement = "\"" + redactBody(string(s[(start + 1)...]), cue: cue, rules)
                    } else {
                        replacement = "\"" + redactBody(string(s[(start + 1)..<(valueEnd - 1)]), cue: cue, rules) + "\""
                    }
                } else if start < s.count, s[start] == "-" || ("0"..."9").contains(s[start]) {
                    while valueEnd < s.count, !s[valueEnd].properties.isWhitespace, !",}]".unicodeScalars.contains(s[valueEnd]) {
                        valueEnd += 1
                    }
                    let value = string(s[start..<valueEnd])
                    let redacted = cued(value, cue: cue, rules)
                    if redacted != value { replacement = "\"" + encodeBody(redacted) + "\"" }
                }
                if let replacement {
                    out += string(s[open..<start]) + replacement
                    looseStart = valueEnd
                    i = s.firstIndex(of: "\"", from: valueEnd)
                    continue
                }
            }
            out += complete && isKey ? token : "\"" + redactBody(string(s[(open + 1)..<(end - 1)]), cue: nil, rules) + "\""
            looseStart = end
            i = s.firstIndex(of: "\"", from: end)
        }
        if let open = i {
            // Text before the unterminated string, then the string on its own.
            flush(open)
            looseStart = open
        }
        flush(s.count)
        return out
    }

    // MARK: Helpers

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: scalars)
        return String(v)
    }

    private static func skipWhitespace(_ s: Scalars, _ from: Int) -> Int {
        var i = from
        while i < s.count, s[i].properties.isWhitespace { i += 1 }
        return i
    }

    /// Index just past the string token that opens at `start`, or -1 if it never closes.
    private static func stringTokenEnd(_ s: Scalars, _ start: Int) -> Int {
        var i = start + 1
        while i < s.count {
            if s[i] == "\\" { i += 2; continue }
            if s[i] == "\"" { return i + 1 }
            i += 1
        }
        return -1
    }

    private static func apply(_ rules: [PIIRedactor.Compiled], _ text: String) -> String {
        rules.reduce(text) { PIIRedactor.apply($1, to: $0) }
    }

    private static func cued(_ value: String, cue: String?, _ rules: [PIIRedactor.Compiled]) -> String {
        guard let cue else { return apply(rules, value) }
        return string(apply(rules, cue + value).unicodeScalars.dropFirst(cue.unicodeScalars.count))
    }

    /// A string token's body (no quotes): decoded, redacted, re-encoded only if changed.
    private static func redactBody(_ raw: String, cue: String?, _ rules: [PIIRedactor.Compiled]) -> String {
        let decoded = decodeEscapes(raw)
        let redacted = cued(decoded, cue: cue, rules)
        return redacted == decoded ? raw : encodeBody(redacted)
    }

    /// Text outside complete string tokens in JSON that doesn't parse. A leading quote marks an
    /// unterminated string. Other text has its escapes decoded for the rules, and only the
    /// matched characters are replaced, so untouched escapes stay as written.
    private static func redactLoose(_ text: String, _ rules: [PIIRedactor.Compiled]) -> String {
        if text.unicodeScalars.first == "\"" {
            return "\"" + redactBody(String(text.unicodeScalars.dropFirst()), cue: nil, rules)
        }
        if !text.unicodeScalars.contains("\\") { return apply(rules, text) }
        // Pieces: one source character or one well-formed escape, each decoding to one character.
        var pieces: [String] = splitPieces(Array(text.unicodeScalars))
        for rule in rules {
            var decoded = ""
            var offsets: [Int] = []   // UTF-16 offset where each piece starts in `decoded`
            var utf16 = 0
            for piece in pieces {
                offsets.append(utf16)
                let d = decodeEscapes(piece)
                decoded += d
                utf16 += d.utf16.count
            }
            offsets.append(utf16)
            let found = PIIRedactor.edits(rule, in: decoded)
            if found.isEmpty { continue }
            func pieceIndex(_ offset: Int) -> Int { offsets.firstIndex { $0 >= offset } ?? pieces.count }
            var next: [String] = []
            var copied = 0
            for (range, replacement) in found {
                let a = pieceIndex(range.location), b = pieceIndex(range.location + range.length)
                next += pieces[copied..<a]
                next += replacement.unicodeScalars.map { String($0) }
                copied = b
            }
            next += pieces[copied...]
            pieces = next
        }
        return pieces.joined()
    }

    private static func isHex(_ c: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }

    private static let simpleEscapes: [Unicode.Scalar: Unicode.Scalar] = [
        "\"": "\"", "\\": "\\", "/": "/", "b": "\u{08}", "f": "\u{0C}", "n": "\n", "r": "\r", "t": "\t",
    ]

    private static func splitPieces(_ s: Scalars) -> [String] {
        var out: [String] = []
        var i = 0
        while i < s.count {
            if s[i] == "\\", i + 1 < s.count {
                if simpleEscapes[s[i + 1]] != nil { out.append(string(s[i...(i + 1)])); i += 2; continue }
                if s[i + 1] == "u", i + 5 < s.count, s[(i + 2)...(i + 5)].allSatisfy(isHex) {
                    out.append(string(s[i...(i + 5)])); i += 6; continue
                }
            }
            out.append(String(s[i]))
            i += 1
        }
        return out
    }

    /// JSON escapes decoded wherever they are well formed; anything else (a lone backslash, an
    /// escape cut off by truncation) is kept as written. A lone surrogate becomes U+FFFD.
    static func decodeEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains("\\") else { return text }
        let s = Array(text.unicodeScalars)
        var units: [UInt16] = []
        var i = 0
        func hex4(_ at: Int) -> UInt16? {
            guard at + 3 < s.count, s[at...(at + 3)].allSatisfy(isHex) else { return nil }
            return UInt16(string(s[at...(at + 3)]), radix: 16)
        }
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count {
                if let simple = simpleEscapes[s[i + 1]] {
                    units.append(contentsOf: String(simple).utf16); i += 2; continue
                }
                if s[i + 1] == "u", let unit = hex4(i + 2) {
                    units.append(unit); i += 6; continue
                }
            }
            units.append(contentsOf: String(c).utf16)
            i += 1
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The body of a JSON string literal for `value`, without the quotes.
    static func encodeBody(_ value: String) -> String {
        var out = ""
        for c in value.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out
    }
}

private extension Array where Element == Unicode.Scalar {
    func firstIndex(of target: Unicode.Scalar, from: Int) -> Int? {
        var i = from
        while i < count { if self[i] == target { return i }; i += 1 }
        return nil
    }
}
