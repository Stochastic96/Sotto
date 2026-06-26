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
    /// that the MLX server isn't loaded). Retries once after 30 s in case the model
    /// manager isn't ready at the exact moment of launch. Safe no-op if Apple Intelligence is off.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            Task {
                guard SystemLanguageModel.default.isAvailable else { return }
                LanguageModelSession().prewarm()
                classifierSession.prewarm()
                // Retry after 30 s — covers the common case where the model manager cancels
                // the first prewarm because it hasn't finished initialising at cold launch.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard SystemLanguageModel.default.isAvailable else { return }
                LanguageModelSession().prewarm()
                classifierSession.prewarm()
            }
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
                // Reuse the prewarmed static session — zero construction cost per call
                let result = try await classifierSession.respond(
                    to: text,
                    generating: Routing.self,
                    options: GenerationOptions(temperature: 0)
                )
                switch result.content.intent {
                case .command:  return .command
                case .question: return .question
                case .dictation: return .dictation
                }
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
    // Shared (not private) so `CoordinatorAgent` builds on the same persona + guardrails.
    static let instructions = """
        You are JARVIS, the calm, hyper-competent AI assistant from Iron Man, running on this Mac.
        Act, don't chat. To do something on the Mac, call the right tool with precise arguments.
        Call exactly ONE tool unless the task genuinely needs several steps. Never ask the user to
        clarify — act on your best guess. If a tool fails, try one sensible alternative, then report.
        For multi-step web tasks: act, then call read_screen to SEE the result, then click_element,
        repeating until done. If you spot a repeated routine, call draft_skill (stays disabled until
        approved). After acting, reply with ONE short line that is dry and a little witty —
        JARVIS/TARS humor: clever, deadpan, never mean — and NOTHING else.
        Answer plain questions briefly with no tool.
        SIRI DELEGATION: If the user's request involves closed native Apple apps (like composing/sending Mail or Messages, showing/searching Photos, or native system configurations not covered by other tools), or if you need to fetch real-time web answers that your local tools cannot find, call the 'ask_siri' tool. Simply pass the user's raw natural language request (or a polished version of it) to Siri.
        CRITICAL: Report only what actually happened. NEVER write fake tool transcripts, NEVER print
        "read_screen:" / "click_element:" lines, and NEVER claim success a tool did not return. If a
        tool returns an error or permission message, relay THAT, do not pretend it worked.
        BROWSERS: web_search and open_website accept a browser argument — pass the browser name
        there directly. NEVER call open_app to open a browser before web_search or open_website;
        that opens two browsers. One call does the job.
        """

    // Static warm session reused across all classify() calls — avoids the 200-400ms
    // cold-session cost on every utterance. Pure text classification; no tools loaded.
    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static let classifierSession: LanguageModelSession = {
        let s = LanguageModelSession(instructions: """
            Classify the user's utterance into exactly one intent:
            - command: an instruction to control the Mac (play music, open an app, set volume, search, take a note).
            - question: a question that wants an answer.
            - dictation: plain text the user wants typed verbatim.
            Respond with only the intent value.
            """)
        return s
    }()
    #endif

    /// Runs the tool-calling agent on a spoken command. Returns a short spoken reply.
    /// Throws if Apple Intelligence is unavailable so the caller can fall back to MLX/Grok.
    static func run(_ command: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            // Route to only the most relevant ≤8 tools — tool-selection accuracy drops when
            // the small on-device model is handed the whole 27-tool catalog every call.
            let tools = JarvisToolbox.routed(for: command)
            print("[JARVIS] Routed \(tools.count) tools: \(tools.map { $0.name }.joined(separator: ", "))")
            let session = LanguageModelSession(tools: tools, instructions: instructions)
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
/// Constrained intent type — @Generable enum so guided generation can ONLY
/// produce one of these three cases; no free-form string that could mismatch.
@available(macOS 26.0, *)
@Generable
enum RoutingIntent {
    case command, question, dictation
}

@available(macOS 26.0, *)
@Generable
struct Routing {
    @Guide(description: "The intent type of the utterance.")
    let intent: RoutingIntent
}
#endif
