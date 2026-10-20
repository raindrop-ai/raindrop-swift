/// Text-field truncation, identical across Raindrop SDKs.
enum Truncation {
    /// Exact marker every SDK appends to a truncated value.
    static let marker = "...[truncated by raindrop]"

    /// Returns `text` unchanged when it has at most `limit` Unicode codepoints; otherwise
    /// a prefix plus `marker` whose total length (marker included) is exactly `limit`,
    /// matching the TypeScript SDK. Counts codepoints (`unicodeScalars`), not
    /// UTF-16 units or grapheme clusters.
    static func truncate(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard limit > 0, scalars.count > limit else { return text }
        let markerCount = marker.unicodeScalars.count
        guard limit > markerCount else {
            return String(String.UnicodeScalarView(scalars.prefix(limit)))
        }
        return String(String.UnicodeScalarView(scalars.prefix(limit - markerCount))) + marker
    }
}
