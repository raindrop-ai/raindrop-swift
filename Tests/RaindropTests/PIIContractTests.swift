import Foundation
import Testing
@testable import Raindrop

/// The shared PII contract: rules, cue rules, the JSON pass and span content keys, checked
/// against the conformance harness's fixtures (copied into Fixtures/, rules and cases only).
private func fixture(_ name: String) -> [String: Any] {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

private let at = "\u{40}"   // keeps literal addresses out of the source

@Suite struct SharedPIIRules {
    let doc = fixture("pii-redaction")

    @Test func rulesMatchTheFixture() throws {
        let rules = try #require(doc["rules"] as? [[String: Any]])
        #expect(rules.count == PIIRedactor.rules.count)
        for (expected, rule) in zip(rules, PIIRedactor.rules) {
            #expect(expected["name"] as? String == rule.name)
            #expect(expected["pattern"] as? String == rule.pattern, "pattern of \(rule.name)")
            #expect(expected["case_insensitive"] as? Bool == rule.caseInsensitive)
            #expect(expected["replace_with"] as? String == rule.replaceWith)
            #expect(expected["keep_group"] as? Int == rule.keepGroup)
            #expect(expected["not_followed_by"] as? String == rule.notFollowedBy)
            let req = expected["requires_in_group"] as? [String: Any]
            #expect(req?["group"] as? Int == rule.requiresInGroup?.group)
            #expect(req?["pattern"] as? String == rule.requiresInGroup?.pattern)
        }
        #expect(PIIRedactor.compiled != nil)
        let cues = try #require(doc["json_cue_keys"] as? [String: [String]])
        #expect(cues == PIIRedactor.jsonCueKeys)
    }

    private func cases(_ list: String) -> [(String, String, String)] {
        ((doc[list] as? [[String: Any]]) ?? []).map { ($0["id"] as! String, $0["input"] as! String, $0["expected"] as! String) }
    }

    @Test func everyCaseList() {
        for list in ["cases", "cue_cases"] {
            let all = cases(list)
            #expect(!all.isEmpty)
            for (id, input, expected) in all {
                #expect(PIIRedactor.redact(input) == expected, "\(list) \(id)")
            }
        }
        let json = cases("json_cases")
        #expect(!json.isEmpty)
        for (id, input, expected) in json {
            #expect(PIIJSON.redactEventText(input) == expected, "json_cases \(id)")
        }
    }

    @Test func classesAndCaseFoldingAreASCII() {
        // A non-ASCII letter is not a word character: the date is still followed by a boundary.
        #expect(PIIRedactor.redact("DOB: 1990-01-05\u{E9}") == "DOB: <REDACTED DATE OF BIRTH>\u{E9}")
        // Non-ASCII digits are not \d.
        let arabicIndic = "\u{0664}\u{0661}\u{0661}\u{0661} \u{0661}\u{0661}\u{0661}\u{0661} \u{0661}\u{0661}\u{0661}\u{0661} \u{0661}\u{0661}\u{0661}\u{0661}"
        #expect(PIIRedactor.redact(arabicIndic) == arabicIndic)
        // Case folding is ASCII only: the long s (which Unicode folds to s) is not an s.
        #expect(PIIRedactor.redact("PASSWORD: x") == "<REDACTED SECRET>")
        #expect(PIIRedactor.redact("pa\u{17F}\u{17F}word: x") == "pa\u{17F}\u{17F}word: x")
        // Non-ASCII whitespace is not \s.
        #expect(PIIRedactor.redact("creds: user pass") == "<REDACTED CREDENTIALS>")
        #expect(PIIRedactor.redact("creds: user\u{00A0}pass") == "creds: user\u{00A0}pass")
        // Text around astral characters keeps its place.
        #expect(PIIRedactor.redact("\u{1F600} DOB: 1990-01-05 \u{1F600}") == "\u{1F600} DOB: <REDACTED DATE OF BIRTH> \u{1F600}")
    }

    @Test func eventTextVersusSpanContent() {
        // Event text: the rules then run over the whole field.
        #expect(PIIJSON.redactEventText(#"{"order_id":4111111111111111}"#) == #"{"order_id":<REDACTED CREDIT CARD NUMBER>}"#)
        // Span content: the JSON pass only, keys and numbers kept.
        #expect(PIIJSON.redactSpanText(#"{"order_id":4111111111111111}"#) == #"{"order_id":4111111111111111}"#)
        #expect(PIIJSON.redactSpanText("{\"jane\(at)example.com\":\"ok\"}") == "{\"jane\(at)example.com\":\"ok\"}")
        #expect(PIIJSON.redactSpanText(#"[{"note":"call 555-123-4567"}]"#) == #"[{"note":"call <REDACTED PHONE NUMBER>"}]"#)
        #expect(PIIJSON.redactSpanText("plain DOB: 1990-01-05") == "plain DOB: <REDACTED DATE OF BIRTH>")
    }

    @Test func jsonThatDoesNotParseNeverFails() {
        #expect(PIIJSON.redactSpanText(#"{"note":"jane\u0040example.com"#) == #"{"note":"<REDACTED EMAIL>"#)
        #expect(PIIJSON.redactSpanText(#"{"note":"unfinished"#) == #"{"note":"unfinished"#)
        #expect(PIIJSON.redactSpanText("{\"jane\(at)example.com\":\"x") == #"{"<REDACTED EMAIL>":"x"#)
        #expect(PIIJSON.redactSpanText(#"["a", jane\u0040example.com \n"#) == #"["a", <REDACTED EMAIL> \n"#)
        #expect(PIIJSON.redactSpanText(#"{"mrn": 12345"#) == #"{"mrn": "<REDACTED MEDICAL RECORD NUMBER>""#)
        for text in [#"{"a":"\u00"#, #"["x", "\"#, #"{"k":"v"} trailing ""#, #"{"mrn": 12"#, #"[""#, #"{""#, "{\"\u{1F600}\\ud83d"] {
            #expect(PIIJSON.redactEventText(text) != nil)
            #expect(PIIJSON.redactSpanText(text) != nil)
        }
        // Re-encoding escapes what JSON requires.
        #expect(PIIJSON.redactSpanText("[\"tab\\tjane\(at)example.com \\\"q\\\"\"]") == #"["tab\t<REDACTED EMAIL> \"q\""]"#)
    }

    @Test func spanContentKeysMatchTheFixture() throws {
        let doc = fixture("pii-span-content-keys")
        #expect(Set(try #require(doc["content_suffixes"] as? [String])) == SpanPrivacy.contentSuffixes)
        #expect(Set(try #require(doc["content_keys"] as? [String])) == SpanPrivacy.contentKeys)
        #expect(try #require(doc["never_touched_prefixes"] as? [String]) == SpanPrivacy.neverTouchedPrefixes)
        let copies = try #require(doc["event_property_copies"] as? [String: Any])
        #expect(copies["prefixes"] as? [String] == SpanPrivacy.eventPropertyCopyPrefixes)
        #expect(Set(copies["keys"] as? [String] ?? []) == SpanPrivacy.eventPropertyCopyKeys)
        #expect(Set(copies["sdk_own_names"] as? [String] ?? []).isSubset(of: SpanPrivacy.sdkOwnAssociationNames))
        var checked = 0
        for c in try #require(doc["cases"] as? [[String: Any]]) where c["span_fields"] == nil {   // the span field map is not implemented
            let key = c["key"] as! String
            #expect(SpanPrivacy.isContentKey(key) == (c["redact"] as! Bool), "\(key)")
            checked += 1
        }
        #expect(checked > 50)
        // This SDK's own association property for the event name is not caller content.
        #expect(!SpanPrivacy.isContentKey("traceloop.association.properties.event"))
    }

    @Test func redactionComesBeforeTheCap() async {
        let t = FakeTransport()
        let c = makeClient(t) { $0.redactPii = true; $0.maxTextFieldChars = 60 }
        // The address straddles the cap: capping first would ship part of it.
        let input = String(repeating: "x", count: 20) + " reach jane.doe\(at)example.com " + String(repeating: "y", count: 60)
        c.trackAi(AiEvent(userId: "u1", event: "e", input: input, output: "ok"))
        await c.flush()
        let sent = (t.requests[0].array[0]["ai_data"] as? [String: Any])?["input"] as? String ?? ""
        #expect(!sent.contains("jane") && !sent.contains("doe"))
        #expect(sent.hasPrefix(String(repeating: "x", count: 20) + " reach <REDAC"))
        #expect(sent.unicodeScalars.count == 60)
    }
}
