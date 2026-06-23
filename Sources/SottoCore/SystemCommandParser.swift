import Foundation

// MARK: - SystemCommandParser
//
// Deterministic parser for parametric system commands that should be reflexes, not
// model calls — "set volume to 90 percent", "make brightness 60%", "volume 30".
// Today these fall through to the Foundation Models VolumeTool/BrightnessTool, which
// is why "set volume to 90 percent" feels slow next to "Hey Siri, set volume to 90".
//
// Pure logic, no platform imports — lives in SottoCore so it can be unit-tested.

public enum SystemCommandParser {

    public enum Command: Equatable, Sendable {
        case setVolume(percent: Int)      // 0…100
        case setBrightness(percent: Int)  // 0…100
    }

    /// Parses an utterance into a parametric system command, or nil if it isn't one.
    /// Recognizes an explicit numeric target for volume or brightness; relative phrases
    /// ("a bit louder", "dim a little") are intentionally left to the existing
    /// up/down shortcuts and the model.
    /// Words a direct command may open with. Requiring one of these prevents false
    /// fires on embedded mentions like "remind me to set volume to 90 percent".
    private static let commandOpeners = [
        "set", "make", "turn", "change", "adjust", "put",
        "volume", "brightness", "sound", "increase", "decrease", "lower", "raise"
    ]

    public static func parse(_ text: String) -> Command? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Must read as a direct command, not an embedded clause.
        let firstWord = lower.components(separatedBy: .whitespaces).first ?? ""
        guard commandOpeners.contains(firstWord) else { return nil }

        let isVolume = lower.contains("volume") || lower.contains("sound")
        let isBrightness = lower.contains("brightness") || lower.contains("screen brightness")
        guard isVolume || isBrightness else { return nil }

        // Only treat it as a "set to N" command when an explicit target is implied:
        // either a "set"/"make"/"to"/"at" cue, or a percent sign / "percent" word.
        let hasSetCue = lower.contains("set ") || lower.contains("make ")
            || lower.contains(" to ") || lower.contains(" at ")
            || lower.contains("%") || lower.contains("percent")
        guard hasSetCue else { return nil }

        guard let value = firstInteger(in: lower) else { return nil }
        let clamped = max(0, min(100, value))

        // If the utterance somehow mentions both, prefer brightness only when it's the
        // clearer subject; otherwise volume wins (the common case).
        if isVolume { return .setVolume(percent: clamped) }
        return .setBrightness(percent: clamped)
    }

    /// First standalone integer in the string (so "to 90 percent" → 90).
    private static func firstInteger(in s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}
