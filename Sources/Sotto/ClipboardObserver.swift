import AppKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - ClipboardObserver
//
// Watches NSPasteboard every 1.5 s. On change, classifies content deterministically —
// no AI tokens spent unless truly ambiguous. When something is actionable, it emits
// .suggestionReady so EventHandler can show a HUD and the user can say "yes" or ignore.
//
// Example flow:
//   User copies "https://github.com/user/repo"
//     → classifyContent → .githubURL
//     → emit .clipboardChanged
//     → suggestAction → "Clone repo?" with command "clone https://…"
//     → emit .suggestionReady
//     → EventHandler shows HUD: "💡 Clone repo?"
//     → User says "yes" → Jarvis runs: clone https://…

enum ClipboardObserver {

    static func start() {
        Task.detached(priority: .background) { await watch() }
    }

    // MARK: - Main watch loop

    private static func watch() async {
        var lastChangeCount = NSPasteboard.general.changeCount
        var lastText = ""

        while true {
            try? await Task.sleep(for: .seconds(1.5)) // 1.5 s

            let currentCount = NSPasteboard.general.changeCount
            guard currentCount != lastChangeCount else { continue }
            lastChangeCount = currentCount

            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.isEmpty,
                  text != lastText,
                  text.count > 4 else { continue }
            lastText = text

            let kind = classifyContent(text)
            await EventBus.shared.emit(.clipboardChanged(content: text, kind: kind))

            // Only spend tokens/time on actionable content kinds
            if let (message, command) = actionSuggestion(for: text, kind: kind) {
                await EventBus.shared.emit(.suggestionReady(message: message, command: command))
            }
        }
    }

    // MARK: - Deterministic classification (0 tokens)

    static func classifyContent(_ text: String) -> EventBus.ClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("https://github.com") || trimmed.hasPrefix("http://github.com") {
            return .githubURL(trimmed)
        }
        if trimmed.hasPrefix("https://gitlab.com") || trimmed.hasPrefix("http://gitlab.com") {
            return .gitlabURL(trimmed)
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return .genericURL(trimmed)
        }
        if isErrorMessage(trimmed) { return .errorMessage }
        if let lang = detectCode(trimmed) { return .code(language: lang) }
        return .plainText
    }

    private static func isErrorMessage(_ s: String) -> Bool {
        let indicators = ["error:", "Error:", "Exception", "Traceback", "FAILED", "fatal:", "panic:"]
        return indicators.contains(where: { s.hasPrefix($0) })
            || (s.contains("error") && s.contains("line "))
    }

    private static func detectCode(_ s: String) -> String? {
        if s.contains("func ") && (s.contains("->") || s.contains("{")) { return "Swift" }
        if s.contains("def ") && s.contains(":") { return "Python" }
        if (s.contains("function") || s.contains("const ") || s.contains("=>")) && s.contains("{") { return "JavaScript" }
        if s.contains("fn ") && s.contains("->") { return "Rust" }
        if s.contains("public class") || s.contains("void ") { return "Java" }
        return nil
    }

    // MARK: - Action suggestions (deterministic, no AI)

    private static func actionSuggestion(for text: String, kind: EventBus.ClipboardKind) -> (message: String, command: String?)? {
        switch kind {
        case .githubURL(let url):
            let repoName = url.components(separatedBy: "/").last ?? "repository"
            return ("Clone \(repoName)?", "clone \(url)")

        case .gitlabURL(let url):
            let repoName = url.components(separatedBy: "/").last ?? "repository"
            return ("Clone \(repoName) from GitLab?", "clone \(url)")

        case .errorMessage:
            // Let Jarvis explain it — send as incoming command
            let excerpt = String(text.prefix(120))
            return ("Debug this error?", "explain error: \(excerpt)")

        case .code(let lang):
            // Only suggest for short snippets the user might want explained
            guard text.count < 400 else { return nil }
            return ("Explain this \(lang) code?", "explain: \(text.prefix(200))")

        case .genericURL, .plainText, .image:
            return nil
        }
    }
}

// MARK: - Foundation Models: smart clipboard classification (used when deterministic fails)

#if canImport(FoundationModels)
@available(macOS 26.0, *)
extension ClipboardObserver {

    @Generable
    struct ClipboardIntent {
        @Guide(description: "A very short suggestion for what to do with the copied content. Empty string if nothing useful.")
        let suggestion: String
        @Guide(description: "An optional Jarvis command, e.g. 'summarize', 'translate', or empty.")
        let command: String
    }

    /// Fallback for content that doesn't match deterministic patterns.
    /// Only called when content is > 200 chars and not already classified.
    static func intelligentSuggest(_ text: String) async -> (message: String, command: String?)? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard text.count > 200 && text.count < 2000 else { return nil }

        let session = LanguageModelSession(instructions: """
            You see text the user just copied. Suggest ONE short useful action or return empty strings.
            Examples: "Summarize this?" / "Translate to English?" / "Fix grammar?"
            Return empty strings for plain facts, numbers, names, or things with no clear action.
            """)

        guard let result = try? await session.respond(
            to: "Copied text (first 300 chars): \(text.prefix(300))",
            generating: ClipboardIntent.self,
            options: GenerationOptions(temperature: 0)
        ) else { return nil }

        let suggestion = result.content.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = result.content.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestion.isEmpty else { return nil }
        return (suggestion, command.isEmpty ? nil : command)
    }
}
#endif
