import Foundation

/// Classifies a **final** dictation transcript for the explicit "dictation → Jarvis" bridge.
///
/// The bridge lets a user delegate a task to Jarvis from *within dictation* by opening their
/// utterance with the wake word ("Jarvis, open Xcode"). This type is the single source of truth
/// for that decision: the same rules are unit-tested here in isolation and reused by the app
/// (see `AppController.jarvisWakeCommand`, which is now a thin wrapper over `classify`).
///
/// It is intentionally pure — Foundation only, no AppKit, no I/O, no global state — so it is
/// deterministic, `Sendable`, and trivially testable without a microphone.
///
/// **Safety contract:** only a wake word at the *start* of the utterance yields `.delegate`.
/// A "jarvis" token appearing mid-sentence yields `.nearMiss` and MUST NOT auto-delegate —
/// dictated *content* may never trigger an action. Callers are responsible for enforcing that
/// only the final transcript (never a live/partial one) is ever classified.
public enum BridgeDecision: Equatable, Sendable {
    /// Opened with the wake word and carries a task → delegate `command` to Jarvis.
    case delegate(command: String)
    /// Opened with the wake word but nothing followed ("Jarvis") → nothing to execute.
    case noTask
    /// A wake token appears but NOT as the opener → a likely mishear / missed delegation.
    /// Recorded for audit only; the caller treats the utterance as ordinary dictation.
    case nearMiss
    /// No wake token at all → ordinary dictation.
    case none
}

extension BridgeDecision {
    /// Conversational openers that may precede the wake word ("hey jarvis", "ok jarvis").
    /// Kept lowercased for case-insensitive matching.
    public static let openers: Set<String> = ["hey", "hi", "hello", "yo", "ok", "okay"]

    /// Punctuation stripped from a token before comparison (leading/trailing only).
    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:'\"“”‘’()")

    /// Classify a final transcript into a bridge decision. Never throws; empty/whitespace input
    /// maps to `.none`. Preserves the original casing of the extracted `command`.
    public static func classify(_ transcript: String) -> BridgeDecision {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return .none }

        // How many leading tokens form the wake phrase (0 = the utterance doesn't open with it).
        let dropCount: Int
        if isWake(words[0]) {
            dropCount = 1
        } else if words.count > 1, openers.contains(normalize(words[0])), isWake(words[1]) {
            dropCount = 2
        } else {
            dropCount = 0
        }

        if dropCount > 0 {
            let command = words.dropFirst(dropCount).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? .noTask : .delegate(command: command)
        }

        // Not an opener — but does a wake token appear elsewhere? (audit-only signal)
        return words.contains(where: isWake) ? .nearMiss : .none
    }

    /// Convenience: the delegated command if (and only if) this is an explicit delegation.
    public var command: String? {
        if case let .delegate(command) = self { return command }
        return nil
    }

    /// Lowercased token with surrounding punctuation stripped (interior chars untouched).
    private static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: edgePunctuation).lowercased()
    }

    /// True when a token IS the wake word. Tolerant of the "Hejarvis" ASR mishear where the
    /// opener fuses onto "jarvis" (suffix match), but rejects plain non-wake words. This mirrors
    /// the historical `jarvisWakeCommand` rule exactly so Jarvis-mode behavior is unchanged.
    static func isWake(_ word: String) -> Bool {
        let token = normalize(word)
        return token == "jarvis" || token.hasSuffix("jarvis")
    }
}
