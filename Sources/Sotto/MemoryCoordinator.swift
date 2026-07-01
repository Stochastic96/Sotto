import Foundation
import FoundationModels

@Generable
struct ExtractionResult {
    @Guide(description: "Any durable facts or preferences about the user. Translate into simple declarative statements starting with 'User...'.")
    let facts: [String]
    @Guide(description: "Technical terms, proper nouns, jargon, codebase names (like Sotto, Jarvis, MLX), command lines, or acronyms that should be added to the custom vocabulary dictionary for accurate spelling.")
    let vocabulary: [String]
}

/// Background coordinator that subscribes to the EventBus.
/// Uses Apple Intelligence (via direct LanguageModelSession) to analyze user speech (.userSpoke)
/// and conversation turns (.conversationTurn) asynchronously.
/// Automatically learns user preferences, personal facts, and technical jargon to improve dictation.
actor MemoryCoordinator {
    static let shared = MemoryCoordinator()
    
    private var isListening = false
    // Throttle: raw dictation utterances fire .userSpoke on every press, which would double
    // LLM inference load on 8 GB M1. Allow at most one extraction per 2 minutes for
    // both .userSpoke and .conversationTurn events.
    private var lastExtractionAt: Date = .distantPast
    private let extractionInterval: TimeInterval = 120
    
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
            let now = Date()
            guard now.timeIntervalSince(lastExtractionAt) >= extractionInterval else {
                print("[MEMORY-COORDINATOR] Throttled (last extraction \(Int(now.timeIntervalSince(lastExtractionAt)))s ago)")
                break
            }
            lastExtractionAt = now  // claim slot before spawning the background task
            Task(priority: .utility) {
                // 3-second delay: lets the model finish any in-flight polish request
                // before we fire another generation call, avoiding rate-limit / capability
                // errors from back-to-back requests on the same Foundation Models instance.
                try? await Task.sleep(for: .seconds(3))
                await self.extractFactsAndVocabulary(from: text)
            }

        case .conversationTurn(let user, let assistant):
            let now = Date()
            guard now.timeIntervalSince(lastExtractionAt) >= extractionInterval else {
                print("[MEMORY-COORDINATOR] Throttled (last extraction \(Int(now.timeIntervalSince(lastExtractionAt)))s ago)")
                break
            }
            lastExtractionAt = now
            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(3))
                await self.extractFactsAndVocabulary(from: "User: \(user)\nJarvis: \(assistant)")
            }
            
        default:
            break
        }
    }
    
    private func extractFactsAndVocabulary(from text: String) async {
        guard SystemLanguageModel.default.isAvailable else { return }

        let instructions = "You are Jarvis's memory extractor. Extract facts and vocabulary."
        let session = LanguageModelSession(instructions: instructions)
        
        let prompt = """
        Analyze the following text from the user's interaction with the Mac.
        Extract:
        1. "facts": Any durable facts or preferences about the user (e.g. "Name is Prashant", "Prefers Safari", "Working on Sotto project"). Translate into simple declarative statements starting with "User...".
        2. "vocabulary": Technical terms, proper nouns, jargon, codebase names (like Sotto, Jarvis, MLX), command lines, or acronyms that should be added to the custom vocabulary dictionary for accurate spelling.
        
        Input:
        "\(text)"
        """
        
        do {
            let result = try await session.respond(
                to: prompt,
                generating: ExtractionResult.self,
                options: GenerationOptions(temperature: 0.1)
            )
            
            let extracted = result.content
            
            // Save facts to UserProfile and SemanticMemory
            for fact in extracted.facts {
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
            
            for word in extracted.vocabulary {
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
                // Hop to the main actor to read the @MainActor-isolated AppController.shared,
                // then kick refreshUserCaches() on the SottoIntelligence actor from there.
                // Direct access from MemoryCoordinator (non-main actor) would violate isolation.
                Task { @MainActor in
                    if let intel = AppController.shared?.intelligence {
                        await intel.refreshUserCaches()
                    }
                }
            }
        } catch {
            // Apple Intelligence may be busy, rate-limited, or not yet fully ready.
            // This is non-fatal — we just skip this extraction cycle silently.
            print("[MEMORY-COORDINATOR] Extraction skipped (\(error.localizedDescription))")
        }
    }
}
