import Foundation

// MARK: - CommandMatcher Protocol

/// Maps a pre-normalised spoken phrase to a zero-latency shortcut.
///
/// To add a new shortcut category:
///   1. Create a type that conforms to `CommandMatcher`.
///   2. Append it to `CommandEngine.shortcutMatchers`.
///
/// No changes to `checkZeroLatencyShortcut` are needed — the chain
/// picks up new matchers automatically.
protocol CommandMatcher {
    func match(_ text: String) -> CommandEngine.ZeroLatencyShortcut?
}

// MARK: - Concrete Matchers

extension CommandEngine {
    struct WindowMatcher: CommandMatcher {
        func match(_ t: String) -> ZeroLatencyShortcut? { CommandEngine.checkWindowShortcut(for: t) }
    }

    struct BrowserMatcher: CommandMatcher {
        func match(_ t: String) -> ZeroLatencyShortcut? { CommandEngine.checkBrowserShortcut(for: t) }
    }

    struct MediaMatcher: CommandMatcher {
        func match(_ t: String) -> ZeroLatencyShortcut? { CommandEngine.checkMediaShortcut(for: t) }
    }

    /// Ordered chain of zero-latency shortcut matchers. First match wins.
    /// Add new categories by appending a `CommandMatcher` conformance here.
    static let shortcutMatchers: [CommandMatcher] = [
        WindowMatcher(),
        BrowserMatcher(),
        MediaMatcher(),
    ]
}
