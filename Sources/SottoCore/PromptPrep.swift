import Foundation

/// A task the co-pilot can prepare a Claude-ready prompt for. Value type — the
/// template logic lives with each case so adding a use case is a one-line change.
public enum PromptUseCase: Equatable {
    case googleAds
    case linkedInPost(topic: String?)
    case explainScreen
    case custom(instruction: String)

    /// Short human label shown in the review window / HUD.
    public var label: String {
        switch self {
        case .googleAds:     return "Google Ads help"
        case .linkedInPost:  return "LinkedIn post"
        case .explainScreen: return "Explain screen"
        case .custom:        return "Custom prompt"
        }
    }

    /// Whether this use case should capture the current screen (via OCR) as context.
    public var needsScreenContext: Bool {
        switch self {
        case .googleAds, .explainScreen: return true
        case .linkedInPost, .custom:     return false
        }
    }

    /// The instruction Claude receives, before any screen context is appended.
    public var instruction: String {
        switch self {
        case .googleAds:
            return "I'm looking at my Google Ads dashboard. Analyse the campaign metrics below "
                 + "and give me specific, prioritised suggestions to improve performance "
                 + "(CTR, conversions, cost per result). Be concrete and actionable."
        case .linkedInPost(let topic):
            let about = topic.map { " about \($0)" } ?? ""
            return "Write an engaging, professional LinkedIn post\(about). "
                 + "Open with a strong hook, keep it concise, and end with a clear takeaway."
        case .explainScreen:
            return "Explain what's on my screen below in clear, simple terms, "
                 + "and tell me what I should do next."
        case .custom(let instruction):
            return instruction
        }
    }
}

/// An assembled, ready-to-send prompt. `Codable` so it persists across sessions
/// for batch workflows ("prep it now, send it to Claude later").
public struct PreppedPrompt: Codable, Equatable {
    public let id: UUID
    public let useCaseLabel: String
    public let assembledText: String
    public let createdAt: Date

    public init(id: UUID, useCaseLabel: String, assembledText: String, createdAt: Date) {
        self.id = id
        self.useCaseLabel = useCaseLabel
        self.assembledText = assembledText
        self.createdAt = createdAt
    }
}

/// Assembles a `PreppedPrompt` from a use case plus optional OCR'd screen text.
public enum PromptBuilder {
    public static func build(_ useCase: PromptUseCase, screenText: String?) -> PreppedPrompt {
        var text = useCase.instruction
        if useCase.needsScreenContext,
           let screenText = screenText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !screenText.isEmpty {
            text += "\n\nHere is the content currently on my screen "
                 +  "(captured via OCR — it may contain minor errors):\n"
                 +  "\"\"\"\n\(screenText)\n\"\"\""
        }
        return PreppedPrompt(id: UUID(),
                             useCaseLabel: useCase.label,
                             assembledText: text,
                             createdAt: Date())
    }
}

/// Disk-backed (UserDefaults) store for the most recently prepared prompt — the
/// lightweight "memory" that lets a later voice command send it to Claude. Costs
/// no RAM; survives restarts.
public enum PromptStore {
    private static let lastKey = "sotto_last_prepped_prompt"

    public static func save(_ prompt: PreppedPrompt) {
        guard let data = try? JSONEncoder().encode(prompt) else { return }
        UserDefaults.standard.set(data, forKey: lastKey)
    }

    public static func loadLast() -> PreppedPrompt? {
        guard let data = UserDefaults.standard.data(forKey: lastKey),
              let prompt = try? JSONDecoder().decode(PreppedPrompt.self, from: data) else { return nil }
        return prompt
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: lastKey)
    }
}
