import Foundation

// MARK: - CommandSplitter
//
// Splits a compound utterance ("open finder and open xcode", "lock the screen
// then sleep") into its individual clauses so the kernel can run each one through
// the reflex path instead of handing the whole sentence to the model.
//
// Pure logic, no platform imports — lives in SottoCore so it can be unit-tested.

public enum CommandSplitter {

    /// Conjunctions that separate independent commands. Order matters only in that
    /// we replace the longer/safer ones; all are treated as the same boundary.
    private static let separators = [" and then ", " then ", " and ", "; "]

    /// Breaks `text` into ordered clauses. Returns a single-element array when the
    /// utterance has no recognized conjunction, so callers can treat the no-split
    /// case uniformly.
    ///
    /// Splitting is intentionally conservative: it only fires on explicit
    /// conjunctions (`and`, `then`, `;`), never on commas, because "open xcode,
    /// finder" is ambiguous and a comma often appears inside a single command.
    public static func clauses(_ text: String) -> [String] {
        var parts = [text]
        for sep in separators {
            parts = parts.flatMap { part -> [String] in
                part.components(separatedBy: sep)
            }
        }
        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? [text] : cleaned
    }

    /// True when the utterance contains at least one recognized conjunction, i.e.
    /// `clauses(_:)` would return more than one clause.
    public static func isCompound(_ text: String) -> Bool {
        clauses(text).count > 1
    }
}
