import Foundation

// MARK: - Punctuation stripping

extension String {
    /// Removes trailing `.,?!` characters in-place.
    mutating func stripTrailingPunctuation() {
        while last == "." || last == "," || last == "?" || last == "!" {
            removeLast()
        }
    }

    /// Returns a copy with trailing `.,?!` removed.
    func strippingTrailingPunctuation() -> String {
        var s = self; s.stripTrailingPunctuation(); return s
    }
}
