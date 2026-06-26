import Foundation

/// Background coordinator that subscribes to the EventBus.
/// Uses Apple Intelligence (via SottoIntelligence) to analyze user speech (.userSpoke)
/// and conversation turns (.conversationTurn) asynchronously.
/// Automatically learns user preferences, personal facts, and technical jargon to improve dictation.
actor MemoryCoordinator {
    static let shared = MemoryCoordinator()
    
    private var isListening = false
    
    struct ExtractionResult: Codable {
        let facts: [String]
        let vocabulary: [String]
    }
    
    func start() {
        guard !isListening else { return }
        isListening = true
        
        Task.detached(priority: .background) {
            print("[MEMORY-COORDINATOR] Started — subscribing to EventBus.")
            for await event in await EventBus.shared.makeStream() {
                await self.handle(event)
            }
        }
    }
    
    private func handle(_ event: EventBus.Event) async {
        switch event {
        case .userSpoke(let text):
            Task(priority: .utility) {
                // 3-second delay: lets the model finish any in-flight polish request
                // before we fire another generation call, avoiding rate-limit / capability
                // errors from back-to-back requests on the same Foundation Models instance.
                try? await Task.sleep(for: .seconds(3))
                await self.extractFactsAndVocabulary(from: text)
            }

        case .conversationTurn(let user, let assistant):
            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(3))
                await self.extractFactsAndVocabulary(from: "User: \(user)\nJarvis: \(assistant)")
            }
            
        default:
            break
        }
    }
    
    private func extractFactsAndVocabulary(from text: String) async {
        let refiner = await MainActor.run { AppController.shared?.intelligenceEngine }
        guard let refiner else { return }
        
        let prompt = """
        Analyze the following text from the user's interaction with the Mac.
        Extract:
        1. "facts": Any durable facts or preferences about the user (e.g. "Name is Prashant", "Prefers Safari", "Working on Sotto project"). Translate into simple declarative statements starting with "User...".
        2. "vocabulary": Technical terms, proper nouns, jargon, codebase names (like Sotto, Jarvis, MLX), command lines, or acronyms that should be added to the custom vocabulary dictionary for accurate spelling.
        
        Input:
        "\(text)"
        
        Response MUST be a valid JSON object matching this schema. Do not include markdown tags (e.g. no ```json) or explanations:
        {
          "facts": ["declarative statement 1", "declarative statement 2"],
          "vocabulary": ["term 1", "term 2"]
        }
        """
        
        do {
            let response = try await refiner.getCompletion(
                systemPrompt: "You are Jarvis's memory extractor. Extract facts and vocabulary in pure JSON.",
                userPrompt: prompt,
                temperature: 0.1,
                maxTokens: 250
            )
            
            let cleaned = SottoIntelligence.cleanup(response)
            guard let data = cleaned.data(using: .utf8) else { return }
            
            let decoder = JSONDecoder()
            if let result = try? decoder.decode(ExtractionResult.self, from: data) {
                // Save facts to UserProfile and SemanticMemory
                for fact in result.facts {
                    let key = fact.lowercased()
                        .components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .filter { !$0.isEmpty }
                        .prefix(4)
                        .joined(separator: "_")
                    if !key.isEmpty {
                        UserProfile.remember(key: String(key), fact: fact)
                        print("[MEMORY-COORDINATOR] Learned fact: \(fact)")
                    }
                }
                
                // Save new vocabulary words to custom vocabulary list
                var currentVocab = UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? []
                var updated = false
                
                // Also get the standard custom vocabulary list to avoid duplicates
                let standardVocab = SettingsController.customVocabulary
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                
                for word in result.vocabulary {
                    let cleanedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard cleanedWord.count >= 2 else { continue }
                    if !currentVocab.contains(cleanedWord) && !standardVocab.contains(cleanedWord) {
                        currentVocab.append(cleanedWord)
                        updated = true
                        print("[MEMORY-COORDINATOR] Learned vocabulary: \(cleanedWord)")
                    }
                }
                
                if updated {
                    UserDefaults.standard.set(currentVocab, forKey: "sotto_learned_vocabulary")
                }
            }
        } catch {
            // Apple Intelligence may be busy, rate-limited, or not yet fully ready.
            // This is non-fatal — we just skip this extraction cycle silently.
            print("[MEMORY-COORDINATOR] Extraction skipped (\(error.localizedDescription))")
        }
    }
}
