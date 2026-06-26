import Foundation

#if SOTTO_MLX
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

/// In-process, on-device Qwen via MLX-Swift (no Python, no server, no network at
/// inference time). Used for heavier / long-form generation; the model weights are
/// loaded once and kept warm in memory so subsequent calls are fast. A fresh
/// `ChatSession` is created per call so requests don't bleed into each other.
///
/// When the MLX packages aren't built into the app this whole engine is a safe no-op
/// (`prepareIfNeeded()` returns false) and callers fall back to Apple Intelligence.
actor MLXEngine {
    static let shared = MLXEngine()
    private init() {}

    #if SOTTO_MLX

    private var container: ModelContainer?
    private var loadFailed = false

    /// Loads (and warms) the model on first use. Returns false if MLX is unavailable
    /// or the model can't be loaded, so the caller can fall back gracefully.
    func prepareIfNeeded() async -> Bool {
        if container != nil { return true }
        if loadFailed { return false }

        let id = SettingsController.modelIdentifier
        print("[MLX] Loading \(id) in-process (first use)…")
        do {
            let loaded = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: id))
            container = loaded
            print("[MLX] \(id) loaded and warm.")
            return true
        } catch {
            print("[MLX] Failed to load \(id): \(error.localizedDescription). Falling back to Apple Intelligence.")
            loadFailed = true
            return false
        }
    }

    func generate(
        systemPrompt: String,
        userPrompt: String,
        history: [(user: String, assistant: String)] = [],
        temperature: Float,
        maxTokens: Int,
        onProgress: (@Sendable @MainActor (String) -> Void)? = nil
    ) async throws -> String {
        guard let container else {
            throw NSError(domain: "MLXEngine", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "MLX model not loaded."])
        }
        var params = GenerateParameters(temperature: temperature)
        params.maxTokens = maxTokens
        
        let session: ChatSession
        if history.isEmpty {
            session = ChatSession(container, instructions: systemPrompt, generateParameters: params)
        } else {
            var chatHistory: [Chat.Message] = []
            for turn in history {
                chatHistory.append(.user(turn.user))
                chatHistory.append(.assistant(turn.assistant))
            }
            session = ChatSession(container, instructions: systemPrompt, history: chatHistory, generateParameters: params)
        }
        
        if let onProgress {
            let stream = session.streamResponse(to: userPrompt)
            var accumulated = ""
            for try await chunk in stream {
                accumulated += chunk
                let cleaned = SottoIntelligence.cleanup(accumulated)
                if !cleaned.isEmpty {
                    await onProgress(cleaned)
                }
            }
            return accumulated
        } else {
            return try await session.respond(to: userPrompt)
        }
    }

    /// Free the resident weights (e.g. on memory pressure on 8 GB Macs).
    func unload() {
        container = nil
        loadFailed = false
    }

    #else

    func prepareIfNeeded() async -> Bool { false }

    func generate(
        systemPrompt: String,
        userPrompt: String,
        history: [(user: String, assistant: String)] = [],
        temperature: Float,
        maxTokens: Int,
        onProgress: (@Sendable @MainActor (String) -> Void)? = nil
    ) async throws -> String {
        throw NSError(domain: "MLXEngine", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "MLX is not built into this binary."])
    }

    func unload() {}

    #endif
}
