import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where a spoken utterance should be routed. Cheap to compute, drives the
/// three-tier speed model (deterministic Swift → Apple FM → MLX/Grok).
enum RoutedIntent: String, Sendable {
    case dictation   // plain text to type verbatim
    case command     // an action to perform on the Mac (tool-callable)
    case question    // a question to answer
}

/// The on-device "brain": classifies intent and runs the native tool-calling agent
/// via Apple's Foundation Models. Falls back gracefully when Apple Intelligence is
/// unavailable (callers then use the MLX/Grok path).
enum JarvisAgent {

    /// Whether the on-device model is usable right now.
    static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static func availabilityError() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This device does not support Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is turned off. Please enable it in System Settings."
                case .modelNotReady:
                    return "The Apple Intelligence model is still downloading or not ready."
                @unknown default:
                    return "Apple Intelligence is unavailable."
                }
            }
        }
        #endif
        return "Apple Intelligence is not supported on this version of macOS."
    }

    /// Reduce first-token latency by warming the model at launch (we have the RAM now
    /// that the MLX server isn't loaded). Safe no-op if Apple Intelligence is off.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            LanguageModelSession().prewarm()
        }
        #endif
    }

    // MARK: - Routing (Tier 1 classifier)

    /// Fast deterministic pre-check, then a tiny constrained FM call only when ambiguous.
    /// Returns nil if the on-device model can't be used (caller falls back).
    static func classify(_ text: String) async -> RoutedIntent? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Tier 0: obvious questions never need the model to classify.
        if lower.hasPrefix("who ") || lower.hasPrefix("what ") || lower.hasPrefix("when ")
            || lower.hasPrefix("where ") || lower.hasPrefix("why ") || lower.hasPrefix("how ")
            || lower.hasSuffix("?") {
            return .question
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let session = LanguageModelSession(instructions: """
                    Classify the user's utterance into exactly one intent:
                    - command: an instruction to control the Mac (play music, open an app, set volume, search, take a note).
                    - question: a question that wants an answer.
                    - dictation: plain text the user wants typed verbatim.
                    Respond with only the intent value.
                    """)
                let result = try await session.respond(to: text, generating: Routing.self,
                                                        options: GenerationOptions(temperature: 0))
                return RoutedIntent(rawValue: result.content.intent.lowercased()) ?? .dictation
            } catch {
                print("[ROUTER] Apple classify failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - Agent (native tool calling)

    // Deliberately SHORT (well under the ~4k-token window). Tool schemas are injected
    // automatically, so the catalog is NOT spelled out here. "JARVIS from Iron Man" gives
    // the model a clear, compact persona without a giant prompt.
    private static let instructions = """
        You are JARVIS, the calm, hyper-competent AI assistant from Iron Man, running on this Mac.
        Act, don't chat. To do something on the Mac (music, volume, brightness, open apps/websites,
        notes, web search) call the right tool with precise arguments.
        For multi-step web tasks: take the first action, then call read_screen to SEE the result,
        then click_element on the right link/button, repeating until the task is done.
        If you notice a repeated multi-step routine, call draft_skill to save it (it stays disabled
        until the user approves). To answer "what did you do / learn", call recall_history and
        summarize. After acting, reply with ONE short, dry confirmation line. Answer plain questions
        briefly with no tool. Never invent tool results — if unsure what's on screen, call read_screen.
        """

    /// Runs the tool-calling agent on a spoken command. Returns a short spoken reply.
    /// Throws if Apple Intelligence is unavailable so the caller can fall back to MLX/Grok.
    static func run(_ command: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(tools: JarvisToolbox.all(), instructions: instructions)
            let response = try await session.respond(to: command,
                                                     options: GenerationOptions(temperature: 0.3))
            return response.content
        }
        #endif
        throw NSError(domain: "JarvisAgent", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is unavailable on this machine."])
    }
}

#if canImport(FoundationModels)
/// Constrained classification output (avoids JSON parsing/repair).
@available(macOS 26.0, *)
@Generable
struct Routing {
    @Guide(description: "One of: command, question, dictation")
    let intent: String
}
#endif
