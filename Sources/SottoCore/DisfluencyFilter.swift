import Foundation

/// Removes standalone filler / hesitation words ("um", "uh", "mm", "blah", …) from a
/// dictated transcript. This runs DETERMINISTICALLY on every dictation — independent of
/// whether AI polish runs, is skipped (short utterances), or is rejected — so fillers
/// never leak into the pasted text just because the model didn't get a turn.
///
/// Matching is whole-word and case-insensitive. Fillers embedded inside real words are
/// never touched ("summer" keeps its "um", "ahead" keeps its "ah"). Trailing sentence
/// punctuation on a removed filler ("uh.") is reattached to the previous kept word so a
/// full stop isn't lost.
public enum DisfluencyFilter {
    /// Whole-word filler tokens to drop. Lowercased; compared case-insensitively.
    public static let fillers: Set<String> = [
        "um", "umm", "ummm",
        "uh", "uhh", "uhhh", "uhm", "erm",
        "hmm", "hmmm", "mm", "mmm", "mhm",
        "er", "err",
        "ah", "ahh", "ahem",
        "blah",
    ]

    private static let sentencePunctuation = Set<Character>(".!?,;:")

    /// Returns `text` with standalone filler tokens removed and spacing tidied.
    public static func strip(_ text: String) -> String {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []

        for token in parts {
            // Compare the token's core (without surrounding punctuation) to the filler set.
            let core = token
                .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
                .lowercased()

            if !core.isEmpty, fillers.contains(core) {
                // Preserve a trailing sentence mark by moving it onto the previous word.
                if let last = token.last, sentencePunctuation.contains(last),
                   var prev = kept.popLast() {
                    if !prev.hasSuffix(String(last)) { prev += String(last) }
                    kept.append(prev)
                }
                continue
            }
            if !token.isEmpty { kept.append(token) }
        }

        var result = kept.joined(separator: " ")
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        result = result
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If we stripped a leading filler and the sentence now starts lowercase but the
        // original started uppercase, restore the capital.
        if let first = result.first, first.isLowercase,
           let origFirst = text.trimmingCharacters(in: .whitespaces).first, origFirst.isUppercase {
            result = result.prefix(1).uppercased() + result.dropFirst()
        }
        return result
    }
}
