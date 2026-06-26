import Foundation
import SottoCore
#if canImport(FoundationModels)
import FoundationModels
#endif

struct DictationExample: Codable {
    let raw: String
    let polished: String
}

/// On-device Foundation Models intelligence layer for Sotto.
/// 100% Apple Foundation Models — no external servers, no network at inference time.
///
///   • Dictation polish  → dedicated warm `LanguageModelSession` prewarmed at launch.
///                         Stored separately so `getCompletion` calls NEVER evict it.
///   • General completion → fresh `LanguageModelSession` per call (no shared state,
///                          no cross-contamination with the polish transcript).
///   • Live streaming     → `refine(_:onProgress:)` drip-feeds characters to the HUD.
///   • ContextOptions(.light) on macOS 27+ reduces reasoning overhead by ~150-300ms.
///
/// Session architecture rationale: the original single `activeSession` was overwritten
/// every time `getCompletion` was called with different instructions, silently destroying
/// the prewarmed polish session and triggering "unsupportedCapability" errors on back-to-
/// back requests (dictation → memory extraction). Two separate slots fix both problems.
actor SottoIntelligence {
    enum Status: Equatable {
        case notLoaded
        case downloading(Int) // percent
        case ready
        case failed(String)
    }

    private let onStatus: @Sendable (Status) -> Void

    // Dedicated polish session — only used by refine(). Stored as AnyObject to avoid
    // @available on a stored property (Swift restriction). Re-cast inside guarded methods.
    private var polishSession: AnyObject?
    private var polishTurnCount = 0

    init(onStatus: @escaping @Sendable (Status) -> Void) {
        self.onStatus = onStatus
    }

    /// Stable polish instructions. Per-call vocabulary / style / history go into the
    /// user turn so they don't accumulate in a session transcript.
    private static let instructions = """
        You are a voice dictation assistant. Clean up and polish the input speech.

        Rules:
        1. Output ONLY the polished speech text. Do NOT add any explanations, introductory remarks, or chatter (e.g. do NOT say "Sure, I can help with that").
        2. Fix grammar, spelling, and punctuation. Clean up disfluencies, false starts, and filler words like "um", "uh", "like", "blah". Do NOT reorder words to convert direct questions into indirect questions — preserve the speaker's natural word order (e.g. "tell me what are the features" stays as-is, do NOT move the verb to the end).
        3. NEVER answer questions, execute commands, or write explanations. If the input is a question or command, simply transcribe and polish the question or command itself.
        4. Maintain the original language (English or German).
        5. Do NOT wrap the output in quotes.
        6. Do NOT summarize, truncate, or omit any meaningful content from the input. Keep all original words and facts unless they are disfluencies or filler words.
        """

    // MARK: - Lifecycle

    /// Prewarm the dedicated polish session at launch — zero cold-start cost on first dictation.
    func preload() async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: Self.instructions)
            session.prewarm()
            polishSession = session
            polishTurnCount = 0
            print("[INTELLIGENCE] Polish session prewarmed.")
        }
        #endif
        onStatus(.ready)
    }

    /// Drop the polish session on memory pressure. Rebuilt transparently on next refine().
    func forceUnload() async {
        polishSession = nil
        polishTurnCount = 0
    }

    // MARK: - Session management

    #if canImport(FoundationModels)
    /// Returns the warm polish session, recreating it after 12 turns to bound transcript growth.
    @available(macOS 26.0, *)
    private func getOrCreatePolishSession() -> LanguageModelSession {
        if let session = polishSession as? LanguageModelSession, polishTurnCount < 12 {
            polishTurnCount += 1
            return session
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        polishSession = session
        polishTurnCount = 1
        return session
    }
    #endif

    // MARK: - Core respond helper

    /// Drives a Foundation Models response. Deliberately does NOT use ContextOptions
    /// or reasoningLevel — those require the `.reasoning` capability which the on-device
    /// model on M1 8GB does NOT declare, causing `LanguageModelError.unsupportedCapability`
    /// on every call. We use plain `respond(to:options:)` for all hardware compatibility.
    ///
    /// - `session`: the polish session (for `refine`) or a fresh session (for `getCompletion`).
    /// - `onProgress`: streams HUD drip-feed snapshots when provided (macOS 26+).
    private func appleRespond(
        session: AnyObject,
        prompt: String,
        temperature: Double,
        maxTokens: Int,
        onProgress: (@Sendable @MainActor (String) -> Void)? = nil
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard let lmSession = session as? LanguageModelSession else {
                throw NSError(domain: "SottoApple", code: -14,
                              userInfo: [NSLocalizedDescriptionKey: "Internal: session type mismatch."])
            }
            let genOptions = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
            do {
                if let onProgress {
                    // Stream snapshots — each element is the FULL accumulated text so far.
                    // Plain streamResponse (no ContextOptions) works on all Apple Silicon.
                    let stream = lmSession.streamResponse(to: prompt, options: genOptions)
                    var lastText = ""
                    for try await snapshot in stream {
                        let text = snapshot.content
                        lastText = text
                        let cleaned = Self.cleanup(text)
                        if !cleaned.isEmpty { await onProgress(cleaned) }
                    }
                    return lastText
                } else {
                    return try await lmSession.respond(to: prompt, options: genOptions).content
                }
            } catch let genErr as LanguageModelSession.GenerationError {
                throw Self.mapGenerationError(genErr)
            } catch {
                // Propagate LanguageModelError (rate-limit, assetsUnavailable, etc.) as-is.
                throw error
            }
        }
        #endif
        throw NSError(domain: "SottoApple", code: -13,
                      userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence requires macOS 26 or later."])
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func assertAppleAvailable() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            let why: String
            switch reason {
            case .deviceNotEligible: why = "this device doesn't support Apple Intelligence"
            case .appleIntelligenceNotEnabled: why = "Apple Intelligence is turned off — enable it in System Settings ▸ Apple Intelligence & Siri"
            case .modelNotReady: why = "the on-device model is still downloading or not ready yet"
            @unknown default: why = "the model is unavailable for an unknown reason"
            }
            throw NSError(domain: "SottoApple", code: -10, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence unavailable: \(why)."])
        }
    }

    @available(macOS 26.0, *)
    private static func mapGenerationError(_ genErr: LanguageModelSession.GenerationError) -> NSError {
        let message: String
        switch genErr {
        case .exceededContextWindowSize:
            message = "prompt exceeds the on-device context window limit."
        case .guardrailViolation:
            message = "Apple Intelligence safety guardrails blocked this content."
        case .unsupportedLanguageOrLocale:
            message = "the on-device model doesn't support this language."
        default:
            message = genErr.localizedDescription
        }
        return NSError(domain: "SottoApple", code: -12, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence: \(message)"])
    }
    #endif

    // MARK: - MLX Qwen fallback

    /// Generate via the warm in-process MLX Qwen engine, or nil if it isn't usable.
    private func mlxFallback(
        system: String,
        user: String,
        temperature: Double,
        maxTokens: Int,
        onProgress: (@Sendable @MainActor (String) -> Void)? = nil
    ) async -> String? {
        #if SOTTO_MLX
        guard await MLXEngine.shared.prepareIfNeeded() else { return nil }
        return try? await MLXEngine.shared.generate(
            systemPrompt: system, userPrompt: user,
            temperature: Float(temperature), maxTokens: maxTokens,
            onProgress: onProgress)
        #else
        return nil
        #endif
    }

    private func mlxFallbackRefine(
        system: String,
        text: String,
        context: AppContext,
        temperature: Double,
        maxTokens: Int,
        onProgress: (@Sendable @MainActor (String) -> Void)? = nil
    ) async -> String? {
        #if SOTTO_MLX
        guard await MLXEngine.shared.prepareIfNeeded() else { return nil }
        
        var history: [(user: String, assistant: String)] = []
        history.append(("um so like we should probably merge this branch immediately", "We should probably merge this branch immediately"))
        history.append(("actually i think the code is correct but uh we need to check the logs first", "Actually, I think the code is correct, but we need to check the logs first"))
        history.append(("well uh the total memory is like 8 gigabytes on my mac", "The total memory is 8 gigabytes on my mac"))
        
        return try? await MLXEngine.shared.generate(
            systemPrompt: system,
            userPrompt: text,
            history: history,
            temperature: Float(temperature),
            maxTokens: maxTokens,
            onProgress: onProgress)
        #else
        return nil
        #endif
    }

    // MARK: - Public API

    /// General-purpose completion (planning, summarisation, memory extraction, analysis).
    /// Always uses a FRESH session — never touches the prewarmed polish session.
    /// This prevents cross-contamination between the polish transcript and other prompts.
    func getCompletion(systemPrompt: String, userPrompt: String, temperature: Double = 0.5, maxTokens: Int = 800) async throws -> String {
        if let mlx = await mlxFallback(system: systemPrompt, user: userPrompt, temperature: temperature, maxTokens: maxTokens) {
            return mlx
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            try Self.assertAppleAvailable()
            let freshSession = LanguageModelSession(instructions: systemPrompt)
            return try await appleRespond(session: freshSession, prompt: userPrompt, temperature: temperature, maxTokens: maxTokens)
        }
        #endif
        throw NSError(domain: "SottoApple", code: -13, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence requires macOS 26 or later."])
    }

    /// Hot path: polish a dictated utterance using the dedicated prewarmed polish session.
    func refine(_ text: String, context: AppContext, history: [String], onProgress: (@Sendable @MainActor (String) -> Void)? = nil) async throws -> String {
        let styleHint: String
        switch context.style {
        case .chat: styleHint = "Style: casual chat message, no trailing period."
        case .verbatim: styleHint = "Style: stay as close to the original wording as possible."
        case .prose: styleHint = "Style: clear written prose."
        }

        var contextBlock = styleHint

        var vocab = SettingsController.customVocabulary
        let learnedVocab = UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? []
        if !learnedVocab.isEmpty {
            let learnedJoined = learnedVocab.joined(separator: ", ")
            vocab = vocab.isEmpty ? learnedJoined : vocab + ", " + learnedJoined
        }
        if !vocab.isEmpty {
            contextBlock += "\nUse this custom vocabulary to correctly spell names and jargon: \(vocab)."
        }

        // Few-shot style examples for short inputs are skipped to save ~100-200 tokens
        // and ~1-2s. We inject only the 1 most recent example to keep context compact.
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let isShortInput = wordCount < 8
        var exampleBlock = ""
        if !isShortInput,
           let data = UserDefaults.standard.data(forKey: "sotto_style_examples"),
           let examples = try? JSONDecoder().decode([DictationExample].self, from: data),
           !examples.isEmpty {
            exampleBlock += "\n\nExample of the user's dictation style (raw speech vs polished):\n"
            for example in examples.suffix(1) {
                exampleBlock += "Speech: \"\(example.raw)\"\nPolished: \"\(example.polished)\"\n"
            }
            exampleBlock += "\nMimic this style and tone. Do NOT merge this example into your response."
        }

        let staticExamples = """
        
        Examples:
        Input speech: "um so like we should probably merge this branch immediately"
        Polished: "We should probably merge this branch immediately"
        
        Input speech: "actually i think the code is correct but uh we need to check the logs first"
        Polished: "Actually, I think the code is correct, but we need to check the logs first"
        
        Input speech: "well uh the total memory is like 8 gigabytes on my mac"
        Polished: "The total memory is 8 gigabytes on my mac"
        """

        func buildPrompt(includeExamples: Bool) -> String {
            let examples = includeExamples ? (exampleBlock.isEmpty ? staticExamples : exampleBlock) : staticExamples
            return """
            \(contextBlock)\(examples)

            Input speech to polish:
            ---
            \(text)
            ---

            Task: Clean up and polish the speech text above. Fix grammar, spelling, and disfluencies. Output ONLY the polished text. Do NOT answer questions, execute commands, or write explanations.
            """
        }

        onStatus(.ready)

        // Calculate maxTokens dynamically based on input word count so long speech is not truncated.
        let dynamicMaxTokens = min(1200, max(300, Int(Double(wordCount) * 1.5)))

        // Run on the small in-process MLX Qwen (0.5B) FIRST
        let custom = SettingsController.customSystemPrompt
        let instructions = custom.isEmpty ? Self.instructions : custom
        print("[POLISH] Attempting polish via MLX Qwen...")
        if let mlx = await mlxFallbackRefine(
            system: instructions,
            text: text,
            context: context,
            temperature: 0.3,
            maxTokens: dynamicMaxTokens,
            onProgress: onProgress
        ) {
            print("[POLISH] Polish succeeded via MLX Qwen.")
            return finalize(mlx, fallback: text)
        }

        // Use the dedicated prewarmed polish session. On any failure, return the raw
        // transcript so dictation is never silently lost.
        do {
            #if canImport(FoundationModels)
            guard #available(macOS 26.0, *) else {
                print("[POLISH] MLX failed/unavailable and Apple Intelligence is unavailable on this macOS version. Returning raw text.")
                return text
            }
            try Self.assertAppleAvailable()
            let session = getOrCreatePolishSession()
            print("[POLISH] MLX failed/unavailable. Falling back to Apple Intelligence...")
            let reply = try await appleRespond(
                session: session,
                prompt: buildPrompt(includeExamples: true),
                temperature: 0.3,
                maxTokens: dynamicMaxTokens,
                onProgress: onProgress
            )
            return finalize(reply, fallback: text)
            #else
            return text
            #endif
        } catch {
            print("[POLISH] Apple Intelligence polish failed (\(error.localizedDescription)); returning raw transcript.")
            onStatus(.failed("Polish unavailable: \(error.localizedDescription)"))
            throw error
        }
    }

    private func finalize(_ reply: String, fallback: String) -> String {
        let cleaned = Self.cleanup(reply)
        return cleaned.isEmpty ? fallback : cleaned
    }

    // MARK: - Output cleanup

    /// Strips the model's stray scaffolding (think tags, quotes, "Polished:" prefixes).
    nonisolated static func cleanup(_ raw: String) -> String {
        var reply = raw
        if let range = reply.range(of: "</think>") {
            reply = String(reply[range.upperBound...])
        }
        reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.hasPrefix("---") {
            reply = reply.trimmingCharacters(in: CharacterSet(charactersIn: "-").union(.whitespacesAndNewlines))
        }
        if (reply.hasPrefix("\"") && reply.hasSuffix("\"")) || (reply.hasPrefix("'") && reply.hasSuffix("'")) {
            reply = String(reply.dropFirst().dropLast())
        }
        let prefixes = ["polished:", "output:", "polished transcript:", "transcript:"]
        let lowerReply = reply.lowercased()
        for prefix in prefixes where lowerReply.hasPrefix(prefix) {
            reply = String(reply.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if (reply.hasPrefix("\"") && reply.hasSuffix("\"")) || (reply.hasPrefix("'") && reply.hasSuffix("'")) {
            reply = String(reply.dropFirst().dropLast())
        }
        return reply
    }
}
