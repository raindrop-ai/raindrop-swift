import Foundation

/// Port of the TypeScript SDK's default `redactPii`. Same patterns, same order, same
/// placeholders, same enabled set: credit card, street address, phone, SSN, email,
/// password, credentials. Zipcode, IP, digits, URL, username and names are disabled by
/// default there too.
enum PIIRedactor {
    private static let aptRegex = #"(apt|bldg|dept|fl|hngr|lot|pier|rm|ste|slip|trlr|unit|#)\.? *[a-z0-9-]+\b"#
    private static let poBoxRegex = #"P\.? ?O\.? *Box +\d+"#
    private static let roadRegex = #"(street|st|road|rd|avenue|ave|drive|dr|loop|court|ct|circle|cir|lane|ln|boulevard|blvd|way)\.?\b"#

    /// (pattern, case-insensitive, replacement), in the JS built-in declaration order.
    private static let rules: [(NSRegularExpression, String)] = {
        let specs: [(String, Bool, String)] = [
            (#"\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}|\d{4}[ -]?\d{6}[ -]?\d{4}\d?"#, false, "<REDACTED CREDIT CARD NUMBER>"),
            ("(\\d+\\s*(\\w+ ){1,2}" + roadRegex + "(\\s+" + aptRegex + ")?)|(" + poBoxRegex + ")", true, "<REDACTED ADDRESS>"),
            (#"(\(?\+?[0-9]{1,2}\)?[-. ]?)?(\(?[0-9]{3}\)?|[0-9]{3})[-. ]?([0-9]{3}[-. ]?[0-9]{4}|\b[A-Z0-9]{7}\b)"#, false, "<REDACTED PHONE NUMBER>"),
            (#"\b\d{3}[ -.]\d{2}[ -.]\d{4}\b"#, false, "<REDACTED SOCIAL SECURITY NUMBER>"),
            (#"([a-z0-9_\-.+]+)@\w+(\.\w+)*"#, true, "<REDACTED EMAIL>"),
            (#"(pass(word|phrase)?|secret): \S+"#, true, "<REDACTED SECRET>"),
            (#"(login( cred(ential)?s| info(rmation)?)?|cred(ential)?s) ?:\s*\S+\s+\/?\s*\S+"#, true, "<REDACTED CREDENTIALS>"),
        ]
        return specs.map { pattern, insensitive, replacement in
            // Patterns are constants verified by unit tests; a failure here is a programming error.
            let regex = try! NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : [])
            return (regex, NSRegularExpression.escapedTemplate(for: replacement))
        }
    }()

    static func redact(_ text: String) -> String {
        var out = text
        for (regex, template) in rules {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    /// Span attributes that carry user or model content. Only these are redacted: ids,
    /// timestamps, token counts and model names would be mangled by the phone/card patterns.
    static func isContentAttribute(_ key: String) -> Bool {
        switch key {
        case "ai.prompt", "ai.prompt.messages", "ai.response.text", "traceloop.entity.input", "traceloop.entity.output":
            return true
        default:
            return (key.hasPrefix("gen_ai.prompt.") || key.hasPrefix("gen_ai.completion.")) && key.hasSuffix(".content")
        }
    }

    /// Redacts the content attributes and the status (error) message of one OTLP span,
    /// then re-applies the text cap (placeholders can lengthen a value).
    static func redactSpan(_ span: inout [String: JSONValue], limit: Int) {
        if case .array(let attributes)? = span["attributes"] {
            span["attributes"] = .array(attributes.map { attr in
                guard var a = attr.objectValue, let key = a["key"]?.stringValue, isContentAttribute(key),
                      var value = a["value"]?.objectValue, let text = value["stringValue"]?.stringValue else { return attr }
                value["stringValue"] = .string(Truncation.truncate(redact(text), limit: limit))
                a["value"] = .object(value)
                return .object(a)
            })
        }
        if var status = span["status"]?.objectValue, let message = status["message"]?.stringValue {
            status["message"] = .string(redact(message))
            span["status"] = .object(status)
        }
    }
}
