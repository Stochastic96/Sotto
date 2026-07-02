import Foundation
import SottoCore
import FoundationModels

// MARK: - IntelligenceEngine Protocol

/// The full public contract for Sotto's on-device AI layer.
///
/// Conform to substitute a different model, a remote backend, or a test stub.
/// `SottoIntelligence` is the production conformance; a `MockIntelligence`
/// can be injected in tests to verify dictation pipeline logic without hitting
/// any real model.
protocol IntelligenceEngine: AnyObject, Sendable {
    /// Warms sessions and loads caches. Call once at launch before any `refine()`.
    func preload() async
    /// Releases in-memory sessions (e.g. on memory-pressure notifications).
    func forceUnload() async
    /// Invalidates cached vocabulary and style examples after a UserDefaults write.
    func refreshUserCaches() async
    /// General-purpose completion for planning, summarisation, and memory extraction.
    func getCompletion(systemPrompt: String, userPrompt: String, temperature: Double, maxTokens: Int) async throws -> String
    /// Hot-path dictation polish — uses the dedicated prewarmed session.
    func refine(_ text: String, context: AppContext, history: [String], onProgress: (@Sendable @MainActor (String) -> Void)?) async throws -> String
}

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
actor SottoIntelligence: IntelligenceEngine {
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
    // Instructions the cached polishSession was actually built with — lets
    // getOrCreatePolishSession() detect a live change to the user's custom prompt
    // (Settings ▸ Custom Instructions) and rebuild rather than serving a stale session.
    private var polishInstructions: String = SottoIntelligence.instructions

    // Cached hot-path values — avoids a UserDefaults read + JSON decode on every refine() call.
    // Invalidated by refreshUserCaches() whenever the underlying defaults change.
    private var cachedVocab: String = ""
    private var cachedStyleExamples: [DictationExample] = []

    init(onStatus: @escaping @Sendable (Status) -> Void) {
        self.onStatus = onStatus
    }

    /// Re-reads vocabulary and style examples from UserDefaults. Call after any write
    /// to `sotto_learned_vocabulary`, `sotto_custom_vocabulary`, or `sotto_style_examples`.
    func refreshUserCaches() {
        let custom = SettingsController.customVocabulary
        let learned = UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? []
        let combined = ([custom] + learned).filter { !$0.isEmpty }.joined(separator: ", ")
        cachedVocab = combined
        if let data = UserDefaults.standard.data(forKey: "sotto_style_examples"),
           let examples = try? JSONDecoder().decode([DictationExample].self, from: data) {
            cachedStyleExamples = examples
        } else {
            cachedStyleExamples = []
        }
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
        7. Do NOT add any fact, name, number, or claim that was not spoken. Polishing means cleaning up how it was said, never adding what wasn't said.
        8. For longer dictation covering more than one distinct thought, break it into short paragraphs at natural topic boundaries instead of one run-on block. If the speaker is clearly enumerating items ("first... second... also...", "one, two, three"), format them as a list. Short, single-thought dictation stays a single line — do not force structure onto it.
        """

    // MARK: - Lifecycle

    /// Prewarm the dedicated polish session at launch — zero cold-start cost on first dictation.
    func preload() async {
        refreshUserCaches()
        if SystemLanguageModel.default.isAvailable {
            let instructions = Self.currentInstructions()
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            polishSession = session
            polishTurnCount = 0
            polishInstructions = instructions
            print("[INTELLIGENCE] Polish session prewarmed.")
        }
        onStatus(.ready)
    }

    /// Drop the polish session on memory pressure. Rebuilt transparently on next refine().
    func forceUnload() async {
        polishSession = nil
        polishTurnCount = 0
    }

    // MARK: - Session management

    /// The active polish instructions: the user's custom prompt (Settings ▸ Custom
    /// Instructions) if set, otherwise the built-in default.
    private static func currentInstructions() -> String {
        let custom = SettingsController.customSystemPrompt
        return custom.isEmpty ? Self.instructions : custom
    }

    /// Returns the warm polish session, recreating it after 12 turns (to bound transcript
    /// growth) or immediately if the user's custom instructions changed since it was built.
    private func getOrCreatePolishSession() -> LanguageModelSession {
        let instructions = Self.currentInstructions()
        if let session = polishSession as? LanguageModelSession,
           polishTurnCount < 12, polishInstructions == instructions {
            polishTurnCount += 1
            return session
        }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        polishSession = session
        polishTurnCount = 1
        polishInstructions = instructions
        return session
    }

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
        } catch let genErr as LanguageModelError {
            throw Self.mapGenerationError(genErr)
        } catch {
            // Propagate LanguageModelError (rate-limit, assetsUnavailable, etc.) as-is.
            throw error
        }
    }

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

    /// Maps the macOS 27 unified `LanguageModelError` to a user-facing message.
    private static func mapGenerationError(_ genErr: LanguageModelError) -> NSError {
        let message: String
        switch genErr {
        case .contextSizeExceeded:
            message = "prompt exceeds the on-device context window limit."
        case .rateLimited:
            message = "Apple Intelligence is rate-limiting requests right now."
        case .guardrailViolation:
            message = "Apple Intelligence safety guardrails blocked this content."
        case .refusal:
            message = "the model declined to respond to this request."
        case .unsupportedCapability(let detail):
            message = "this request needs a capability the on-device model doesn't declare (\(detail.capability))."
        case .unsupportedTranscriptContent:
            message = "the conversation contains content the model can't process."
        case .unsupportedGenerationGuide:
            message = "the requested output format isn't supported."
        case .unsupportedLanguageOrLocale:
            message = "the on-device model doesn't support this language."
        case .timeout:
            message = "the on-device model timed out."
        @unknown default:
            message = genErr.localizedDescription
        }
        return NSError(domain: "SottoApple", code: -12, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence: \(message)"])
    }

    // MARK: - Public API

    /// General-purpose completion (planning, summarisation, memory extraction, analysis).
    /// Always uses a FRESH session — never touches the prewarmed polish session.
    /// This prevents cross-contamination between the polish transcript and other prompts.
    func getCompletion(systemPrompt: String, userPrompt: String, temperature: Double = 0.5, maxTokens: Int = 800) async throws -> String {
        try Self.assertAppleAvailable()
        let freshSession = LanguageModelSession(instructions: systemPrompt)
        return try await appleRespond(session: freshSession, prompt: userPrompt, temperature: temperature, maxTokens: maxTokens)
    }

    /// Hot path: polish a dictated utterance using the dedicated prewarmed polish session.
    func refine(_ text: String, context: AppContext, history: [String], onProgress: (@Sendable @MainActor (String) -> Void)? = nil) async throws -> String {
        let styleHint: String
        switch context.style {
        case .chat: styleHint = "Style: casual chat message, no trailing period."
        case .verbatim: styleHint = "Style: stay as close to the original wording as possible."
        case .prose: styleHint = "Style: clear, professional written prose — the quality of a well-edited email or document, not a raw transcript. Turn run-on spoken sentences into properly punctuated ones. Break distinct thoughts into separate sentences or paragraphs."
        }

        var contextBlock = styleHint

        // Use cached vocab/style to avoid per-call UserDefaults reads and JSON decoding.
        // Cache is populated at preload() and invalidated after each learnFromDictation write.
        if !cachedVocab.isEmpty {
            contextBlock += "\nUse this custom vocabulary to correctly spell names and jargon: \(cachedVocab)."
        }

        // Few-shot style examples for short inputs are skipped to save ~100-200 tokens
        // and ~1-2s. We inject only the 1 most recent example to keep context compact.
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let isShortInput = wordCount < 8
        var exampleBlock = ""
        if !isShortInput, !cachedStyleExamples.isEmpty {
            exampleBlock += "\n\nExample of the user's dictation style (raw speech vs polished):\n"
            for example in cachedStyleExamples.suffix(1) {
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

        Input speech: "so first we need to update the schema and then uh we need to backfill the old rows and then also we should add an index"
        Polished: "First, we need to update the schema. Then we need to backfill the old rows. We should also add an index."
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

        // Use the dedicated prewarmed polish session. On any failure, return the raw
        // transcript so dictation is never silently lost.
        do {
            try Self.assertAppleAvailable()
            let session = getOrCreatePolishSession()
            let reply = try await appleRespond(
                session: session,
                prompt: buildPrompt(includeExamples: true),
                temperature: 0.3,
                maxTokens: dynamicMaxTokens,
                onProgress: onProgress
            )
            return finalize(reply, fallback: text)
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
