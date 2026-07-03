import Foundation

/// Defines Sotto's three conversation lanes: chat, quick, and bigJob.
/// Removed conformance to LanguageModelSession.DynamicProfile to prevent dyld symbol-not-found
/// crashes on OS versions where the experimental builder APIs are missing.
struct JarvisProfile {
    enum Mode: String { case chat, quick, bigJob }

    /// High-precision lane pick. Defaults to `.quick`; only diverts on clear small talk or
    /// clear bulk phrasing, so a genuine command is never starved of tools.
    static func classify(_ input: String) -> Mode {
        let t = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let greetings = ["hi", "hii", "hey", "hello", "yo", "how are you", "how's it going",
                         "hows it going", "good morning", "good afternoon", "good evening",
                         "good night", "thanks", "thank you", "what's up", "whats up", "sup",
                         "you there", "are you there", "good to see you"]
        if t.count < 40, greetings.contains(where: { t == $0 || t.hasPrefix($0 + " ") || t.hasPrefix($0 + ",") }) {
            return .chat
        }

        let bulkMarkers = ["all promotional", "all the promotional", "all my promotional",
                           "delete all", "clean up my inbox", "clean my inbox", "every promotional",
                           "all marketing", "all newsletter", "all the newsletter", "bulk"]
        if bulkMarkers.contains(where: { t.contains($0) }) {
            return .bigJob
        }
        return .quick
    }
}
