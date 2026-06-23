import Foundation

/// Post-transcription vocabulary corrections. Fixes common Parakeet mishears
/// (brand names, camelCase tech terms) and lets you add project-specific words.
///
/// Usage: call `VocabCorrector.apply(to: rawTranscript)` after transcription.
public enum VocabCorrector {
    private static let userDefaultsKey = "sotto_vocab_corrections"

    // Seeded corrections for common Parakeet/ASR mishears.
    // Key: lowercase mis-transcription. Value: correct spelling.
    private static let builtIn: [String: String] = [
        // Tech brand names
        "github":        "GitHub",
        "xcode":         "Xcode",
        "macos":         "macOS",
        "ios":           "iOS",
        "iphone":        "iPhone",
        "ipad":          "iPad",
        "macbook":       "MacBook",
        "airpods":       "AirPods",
        "imac":          "iMac",
        "wifi":          "Wi-Fi",
        "wi fi":         "Wi-Fi",
        "vscode":        "VS Code",
        "vs code":       "VS Code",
        "swiftui":       "SwiftUI",
        "swift ui":      "SwiftUI",
        "appkit":        "AppKit",
        "uikit":         "UIKit",
        "chatgpt":       "ChatGPT",
        "chat gpt":      "ChatGPT",
        "openai":        "OpenAI",
        "open ai":       "OpenAI",
        "javascript":    "JavaScript",
        "typescript":    "TypeScript",
        // Common filler artifact pairs the ASR sometimes logs
        "um uh":         "",
        "uh um":         "",
    ]

    // MARK: - User customisation

    /// Add or overwrite a correction. `mishear` is stored lowercase.
    public static func addCorrection(mishear: String, correct: String) {
        var map = userMap()
        map[mishear.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] = correct
        UserDefaults.standard.set(map, forKey: userDefaultsKey)
    }

    /// Remove a previously added correction.
    public static func removeCorrection(for mishear: String) {
        var map = userMap()
        map.removeValue(forKey: mishear.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        UserDefaults.standard.set(map, forKey: userDefaultsKey)
    }

    /// All user-defined corrections (for display in Settings).
    public static func allUserCorrections() -> [String: String] { userMap() }

    // MARK: - Application

    /// Apply all corrections to `text`. User corrections override built-ins for the same key.
    public static func apply(to text: String) -> String {
        var result = text
        let combined = builtIn.merging(userMap()) { _, user in user }
        for (wrong, right) in combined {
            result = replaceWordBoundary(in: result, wrong: wrong, right: right)
        }
        return result
    }

    // MARK: - Private

    private static func userMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: String] ?? [:]
    }

    private static func replaceWordBoundary(in text: String, wrong: String, right: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b",
            options: .caseInsensitive
        ) else { return text }
        let nsRange = NSRange(text.startIndex..., in: text)
        if right.isEmpty {
            let cleaned = regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: "")
            return cleaned.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        }
        return regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: right)
    }
}
