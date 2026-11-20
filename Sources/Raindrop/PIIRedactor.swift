import Foundation

/// The shared PII redaction rules: the conformance harness's canonical rule set (credit card,
/// street address, phone, SSN, email, password, credentials, then the cue rules for a date of
/// birth and a medical record number), restated from the TypeScript SDK's `redactPii`.
/// Same patterns, same order, same placeholders.
///
/// Semantics the rules are written for, kept exactly:
/// - Rules run in order; each replaces every non-overlapping, leftmost-first match in the
///   previous rule's output.
/// - Character classes are ASCII (`\d` is `[0-9]`, `\w` is `[0-9A-Za-z_]`, `\s` is ASCII
///   whitespace, `\b` an ASCII word boundary) and case-insensitive rules fold ASCII letters
///   only. ICU (`NSRegularExpression`) uses Unicode classes and folding, so every pattern is
///   rewritten into an ASCII-only ICU pattern once, at first use.
/// - `keepGroup`: that group's text (the cue, e.g. `DOB: `) stays in front of the placeholder.
/// - `notFollowedBy`: a match the text right after it starts with is not a match; the search
///   resumes one character after the match's start.
/// - `requiresInGroup`: a match whose group does not contain the pattern is left unchanged;
///   the search resumes after it.
enum PIIRedactor {
    struct Rule: Sendable {
        let name: String
        let pattern: String
        let caseInsensitive: Bool
        let replaceWith: String
        var keepGroup: Int? = nil
        var notFollowedBy: String? = nil
        var requiresInGroup: (group: Int, pattern: String)? = nil
    }

    private static let months = "January|Jan|February|Feb|March|Mar|April|Apr|May|June|Jun|July|Jul|August|Aug|September|Sep|October|Oct|November|Nov|December|Dec"
    private static let day = "(?:3[01]|[12][0-9]|0?[1-9])"
    private static let month = "(?:1[0-2]|0?[1-9])"
    private static let year = "(?:18|19|20)[0-9]{2}"

    /// The rules, in order. A unit test checks them against the harness fixture.
    static let rules: [Rule] = [
        Rule(name: "credit_card",
             pattern: #"\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}|\d{4}[ -]?\d{6}[ -]?\d{4}\d?"#,
             caseInsensitive: false, replaceWith: "<REDACTED CREDIT CARD NUMBER>"),
        Rule(name: "street_address",
             pattern: #"(\d+\s*(\w+ ){1,2}(street|st|road|rd|avenue|ave|drive|dr|loop|court|ct|circle|cir|lane|ln|boulevard|blvd|way)\.?\b(\s+(apt|bldg|dept|fl|hngr|lot|pier|rm|ste|slip|trlr|unit|#)\.? *[a-z0-9-]+\b)?)|(P\.? ?O\.? *Box +\d+)"#,
             caseInsensitive: true, replaceWith: "<REDACTED ADDRESS>"),
        Rule(name: "phone_number",
             pattern: #"(\(?\+?[0-9]{1,2}\)?[-. ]?)?(\(?[0-9]{3}\)?|[0-9]{3})[-. ]?([0-9]{3}[-. ]?[0-9]{4}|\b[A-Z0-9]{7}\b)"#,
             caseInsensitive: false, replaceWith: "<REDACTED PHONE NUMBER>"),
        Rule(name: "us_social_security_number",
             pattern: #"\b\d{3}[ -.]\d{2}[ -.]\d{4}\b"#,
             caseInsensitive: false, replaceWith: "<REDACTED SOCIAL SECURITY NUMBER>"),
        Rule(name: "email_address",
             pattern: #"([a-z0-9_\-.+]+)@\w+(\.\w+)*"#,
             caseInsensitive: true, replaceWith: "<REDACTED EMAIL>"),
        Rule(name: "secret",
             pattern: #"(pass(word|phrase)?|secret): \S+"#,
             caseInsensitive: true, replaceWith: "<REDACTED SECRET>"),
        Rule(name: "credentials",
             pattern: #"(login( cred(ential)?s| info(rmation)?)?|cred(ential)?s) ?:\s*\S+\s+/?\s*\S+"#,
             caseInsensitive: true, replaceWith: "<REDACTED CREDENTIALS>"),
        Rule(name: "date_of_birth",
             pattern: #"(\b(?:d\.?o\.?b\.?|date[ _]?of[ _]?birth|born|birthday)[\t :="']{0,8}(?:on[ ]{1,3})?)(?:"#
                + "\(month)/\(day)/\(year)|\(day)-\(month)-\(year)|\(year)-\(month)-\(day)"
                + "|(?:\(months)) \(day),? \(year)|\(day) (?:\(months)) \(year))",
             caseInsensitive: true, replaceWith: "<REDACTED DATE OF BIRTH>",
             keepGroup: 1, notFollowedBy: "[A-Za-z0-9_]|T[0-9]"),
        Rule(name: "medical_record_number",
             pattern: #"\b((?:MRN|medical record(?: number)?)["']?[\t :#=]{1,8}["']?)([a-z0-9][a-z0-9-]{2,39})\b"#,
             caseInsensitive: true, replaceWith: "<REDACTED MEDICAL RECORD NUMBER>",
             keepGroup: 1, requiresInGroup: (group: 2, pattern: "[0-9]")),
    ]

    /// JSON object keys whose value is redacted as if this cue text came first (the JSON pass).
    static let jsonCueKeys: [String: [String]] = [
        "DOB: ": ["dob", "date of birth", "birthday", "born"],
        "MRN: ": ["mrn", "medical record", "medical record number"],
    ]

    struct Compiled: @unchecked Sendable {
        let regex: NSRegularExpression
        let replacement: String
        let keepGroup: Int?
        let guardRegex: NSRegularExpression?
        let required: (group: Int, regex: NSRegularExpression)?
    }

    /// The compiled rules, or nil if any pattern failed to compile (never expected; unit tests
    /// compile them). Callers fail closed on nil: content is never sent unredacted.
    static let compiled: [Compiled]? = {
        var out: [Compiled] = []
        for rule in rules {
            guard let regex = asciiRegex(rule.pattern, caseInsensitive: rule.caseInsensitive) else { return nil }
            var guardRegex: NSRegularExpression?
            if let g = rule.notFollowedBy {
                guard let r = asciiRegex(g, caseInsensitive: rule.caseInsensitive) else { return nil }
                guardRegex = r
            }
            var required: (group: Int, regex: NSRegularExpression)?
            if let req = rule.requiresInGroup {
                guard let r = asciiRegex(req.pattern, caseInsensitive: rule.caseInsensitive) else { return nil }
                required = (req.group, r)
            }
            out.append(Compiled(regex: regex, replacement: rule.replaceWith, keepGroup: rule.keepGroup,
                                guardRegex: guardRegex, required: required))
        }
        return out
    }()

    // MARK: Plain text

    /// The rules applied to plain text. Returns nil only if the rules are unavailable.
    static func redactIfAvailable(_ text: String) -> String? {
        guard let compiled else { return nil }
        var out = text
        for rule in compiled { out = apply(rule, to: out) }
        return out
    }

    /// The rules applied to plain text. If the rules are unavailable (never expected) the
    /// whole text is replaced, so content never leaves unredacted.
    static func redact(_ text: String) -> String {
        redactIfAvailable(text) ?? failedPlaceholder
    }

    static let failedPlaceholder = "<REDACTION FAILED>"

    /// One rule's replacements as (UTF-16 range, replacement), leftmost-first, non-overlapping.
    static func edits(_ rule: Compiled, in text: String) -> [(NSRange, String)] {
        let ns = text as NSString
        let length = ns.length
        var out: [(NSRange, String)] = []
        var at = 0
        let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        while at <= length {
            guard let m = rule.regex.firstMatch(in: text, options: options, range: NSRange(location: at, length: length - at)) else { break }
            let start = m.range.location
            let end = start + m.range.length
            if let g = rule.guardRegex,
               g.firstMatch(in: text, options: options.union(.anchored), range: NSRange(location: end, length: length - end)) != nil {
                at = start + characterLength(ns, at: start)
                continue
            }
            if let req = rule.required {
                let r = m.range(at: req.group)
                let group = r.location == NSNotFound ? "" : ns.substring(with: r)
                if req.regex.firstMatch(in: group, range: NSRange(location: 0, length: (group as NSString).length)) == nil {
                    at = end > start ? end : start + characterLength(ns, at: start)
                    continue
                }
            }
            var replacement = rule.replacement
            if let keep = rule.keepGroup {
                let r = m.range(at: keep)
                if r.location != NSNotFound { replacement = ns.substring(with: r) + replacement }
            }
            out.append((m.range, replacement))
            at = end > start ? end : start + characterLength(ns, at: start)
        }
        return out
    }

    static func apply(_ rule: Compiled, to text: String) -> String {
        let found = edits(rule, in: text)
        if found.isEmpty { return text }
        let ns = text as NSString
        var out = ""
        var copied = 0
        for (range, replacement) in found {
            out += ns.substring(with: NSRange(location: copied, length: range.location - copied))
            out += replacement
            copied = range.location + range.length
        }
        out += ns.substring(from: copied)
        return out
    }

    /// UTF-16 length of the code point at `index` (2 for a surrogate pair), so a resumed
    /// search never starts inside one.
    private static func characterLength(_ ns: NSString, at index: Int) -> Int {
        guard index < ns.length else { return 1 }
        let unit = ns.character(at: index)
        if UTF16.isLeadSurrogate(unit), index + 1 < ns.length, UTF16.isTrailSurrogate(ns.character(at: index + 1)) { return 2 }
        return 1
    }

    // MARK: ASCII patterns

    private static let wordClass = "0-9A-Za-z_"
    private static let spaceClass = #"\t\n\x{0B}\f\r "#
    private static let asciiBoundary = "(?:(?<=[\(wordClass)])(?![\(wordClass)])|(?<![\(wordClass)])(?=[\(wordClass)]))"
    private static let asciiNonBoundary = "(?:(?<=[\(wordClass)])(?=[\(wordClass)])|(?<![\(wordClass)])(?![\(wordClass)]))"

    /// Compiles `pattern` for ICU with ASCII semantics: `\d \w \s \b` (and their negations)
    /// become explicit ASCII classes and boundaries, and case-insensitivity is spelled out
    /// letter by letter (`[aA]`) instead of ICU's Unicode case folding.
    static func asciiRegex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        guard let translated = asciiPattern(pattern, caseInsensitive: caseInsensitive) else { return nil }
        return try? NSRegularExpression(pattern: translated, options: [])
    }

    static func asciiPattern(_ pattern: String, caseInsensitive: Bool) -> String? {
        let s = Array(pattern.unicodeScalars)
        var out = ""
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\" {
                guard i + 1 < s.count else { return nil }
                let e = s[i + 1]
                switch e {
                case "d": out += "[0-9]"
                case "D": out += "[^0-9]"
                case "w": out += "[\(wordClass)]"
                case "W": out += "[^\(wordClass)]"
                case "s": out += "[\(spaceClass)]"
                case "S": out += "[^\(spaceClass)]"
                case "b": out += asciiBoundary
                case "B": out += asciiNonBoundary
                default: out += "\\" + String(e)
                }
                i += 2
            } else if c == "[" {
                guard let (set, next) = translateClass(s, from: i, caseInsensitive: caseInsensitive) else { return nil }
                out += set
                i = next
            } else if caseInsensitive, let other = otherCase(c) {
                out += "[\(c)\(other)]"
                i += 1
            } else {
                out.unicodeScalars.append(c)
                i += 1
            }
        }
        return out
    }

    private static func otherCase(_ c: Unicode.Scalar) -> Unicode.Scalar? {
        switch c.value {
        case 0x41...0x5A: return Unicode.Scalar(c.value + 32)
        case 0x61...0x7A: return Unicode.Scalar(c.value - 32)
        default: return nil
        }
    }

    /// One `[...]` class from `start` (the `[`): returns it rebuilt from explicit ranges, every
    /// non-alphanumeric character written as `\x{..}` so ICU's set syntax can't reinterpret it.
    private static func translateClass(_ s: [Unicode.Scalar], from start: Int, caseInsensitive: Bool) -> (String, Int)? {
        var i = start + 1
        var negated = false
        if i < s.count, s[i] == "^" { negated = true; i += 1 }
        var ranges: [(UInt32, UInt32)] = []
        var first = true
        func item(_ at: inout Int) -> [(UInt32, UInt32)]? {
            let c = s[at]
            if c == "\\" {
                guard at + 1 < s.count else { return nil }
                let e = s[at + 1]
                at += 2
                switch e {
                case "d": return [(0x30, 0x39)]
                case "w": return [(0x30, 0x39), (0x41, 0x5A), (0x61, 0x7A), (0x5F, 0x5F)]
                case "s": return [(0x09, 0x0D), (0x20, 0x20)]
                case "t": return [(0x09, 0x09)]
                case "n": return [(0x0A, 0x0A)]
                case "r": return [(0x0D, 0x0D)]
                case "f": return [(0x0C, 0x0C)]
                case "v": return [(0x0B, 0x0B)]
                case "D", "W", "S", "b", "B", "x", "u", "p", "P": return nil   // not used by the rules
                default: return [(e.value, e.value)]
                }
            }
            at += 1
            return [(c.value, c.value)]
        }
        while i < s.count {
            if s[i] == "]" && !first { break }
            first = false
            guard let lo = item(&i) else { return nil }
            // A range: single char, '-', single char that isn't the closing ']'.
            if lo.count == 1, lo[0].0 == lo[0].1, i + 1 < s.count, s[i] == "-", s[i + 1] != "]" {
                var j = i + 1
                guard let hi = item(&j), hi.count == 1, hi[0].0 == hi[0].1, hi[0].0 >= lo[0].0 else { return nil }
                ranges.append((lo[0].0, hi[0].0))
                i = j
            } else {
                ranges.append(contentsOf: lo)
            }
        }
        guard i < s.count, s[i] == "]" else { return nil }
        if caseInsensitive {
            var extra: [(UInt32, UInt32)] = []
            for (lo, hi) in ranges {
                let l = max(lo, 0x61), h = min(hi, 0x7A)
                if l <= h { extra.append((l - 32, h - 32)) }
                let L = max(lo, 0x41), H = min(hi, 0x5A)
                if L <= H { extra.append((L + 32, H + 32)) }
            }
            ranges += extra
        }
        func lit(_ v: UInt32) -> String {
            let alnum = (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            return alnum ? String(Unicode.Scalar(v)!) : "\\x{\(String(v, radix: 16))}"
        }
        var body = ""
        for (lo, hi) in ranges { body += lo == hi ? lit(lo) : "\(lit(lo))-\(lit(hi))" }
        return ("[" + (negated ? "^" : "") + body + "]", i + 1)
    }
}
