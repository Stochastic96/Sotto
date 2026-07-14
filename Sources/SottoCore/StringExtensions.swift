import Foundation

// MARK: - Punctuation stripping
//
// Single source of truth for trailing sentence-punctuation removal, shared by both the
// SottoCore and Sotto targets (dictation/Jarvis normalization, command parsing, small
// talk). Previously each call site re-implemented the same `while let last …` loop with a
// slightly different punctuation set; this consolidates them onto one helper.

extension String {
    /// Characters treated as trailing sentence punctuation and stripped.
    private static let trailingSentencePunctuation: Set<Character> = [".", ",", "?", "!", ";", ":"]

    /// Removes trailing sentence punctuation (`.,?!;:`) in place.
    public mutating func stripTrailingPunctuation() {
        while let last, String.trailingSentencePunctuation.contains(last) { removeLast() }
    }

    /// Returns a copy with trailing sentence punctuation (`.,?!;:`) removed.
    public func strippingTrailingPunctuation() -> String {
        var s = self
        s.stripTrailingPunctuation()
        return s
    }
}
