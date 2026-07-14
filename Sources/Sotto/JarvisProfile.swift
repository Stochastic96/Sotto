import Foundation
import SottoCore

/// Defines Sotto's three conversation lanes: chat, quick, and bigJob.
/// Removed conformance to LanguageModelSession.DynamicProfile to prevent dyld symbol-not-found
/// crashes on OS versions where the experimental builder APIs are missing.
struct JarvisProfile {
    enum Mode: String { case chat, quick, bigJob }

    /// High-precision lane pick. Defaults to `.quick`; only diverts on clear small talk or
    /// clear bulk phrasing, so a genuine command is never starved of tools.
    static func classify(_ input: String) -> Mode {
        // Normalize via SmallTalk (the single source of truth for greeting/small-talk
        // phrasings) so lane routing and the zero-token small-talk responder can never
        // drift apart. This also drops trailing sentence punctuation, so "how are you?"
        // matches — without it the "?" defeated every comparison and small talk mis-routed
        // to the tool-loaded quick lane (a ~10 s round-trip instead of the cheap chat lane).
        let t = SmallTalk.normalize(input)

        if t.count < 40,
           SmallTalk.smallTalkPhrases.contains(where: { t == $0 || t.hasPrefix($0 + " ") || t.hasPrefix($0 + ",") }) {
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
