import Foundation

// MARK: - ConversationMemory
//
// Cross-turn continuity for Jarvis. The CoordinatorAgent rebuilds (or continues) a
// LanguageModelSession per top-level command, so without this the assistant forgets
// "what we were just doing" between separate utterances. ConversationMemory keeps a
// small rolling window of recent turns and folds it into a compact digest that
// buildInstructions() injects — giving continuity without re-sending full history
// every turn (which is also the low-token path).
//
// Turns also flow onto the EventBus as `.conversationTurn`, so the bus is the single
// source of conversation history for any future subscriber (analytics, summarizer…).

actor ConversationMemory {
    static let shared = ConversationMemory()

    private struct Turn: Sendable {
        let user: String
        let assistant: String
    }

    /// Rolling window. Kept small: the digest is injected into every Coordinator
    /// session's instructions, so its token cost must stay bounded.
    private var turns: [Turn] = []
    private let maxTurns = 5

    /// Record a completed exchange and publish it on the bus.
    func record(user: String, assistant: String) async {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        turns.append(Turn(user: u, assistant: a))
        if turns.count > maxTurns { turns.removeFirst(turns.count - maxTurns) }
        await EventBus.shared.emit(.conversationTurn(user: u, assistant: a))
    }

    /// A compact digest of recent turns for injection into model instructions, or nil
    /// when there's nothing to carry. Each line is clipped so the whole block stays small.
    func digest() -> String? {
        guard !turns.isEmpty else { return nil }
        let lines = turns.suffix(maxTurns).map { turn -> String in
            "- You said \"\(Self.clip(turn.user))\" → you replied \"\(Self.clip(turn.assistant))\""
        }
        return "Recent conversation (for continuity; only use if the new request refers back to it):\n"
            + lines.joined(separator: "\n")
    }

    func clear() { turns.removeAll() }

    private static func clip(_ s: String, _ max: Int = 90) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count <= max ? collapsed : String(collapsed.prefix(max)) + "…"
    }
}
