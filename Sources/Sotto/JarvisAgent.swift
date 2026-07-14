import Foundation
import FoundationModels

/// Where a spoken utterance should be routed. Cheap to compute, drives the
/// two-tier speed model (deterministic Swift → Apple Foundation Models).
enum RoutedIntent: String, Sendable {
    case dictation   // plain text to type verbatim
    case command     // an action to perform on the Mac (tool-callable)
    case question    // a question to answer
}

/// The on-device "brain": classifies intent and runs the native tool-calling agent
/// via Apple's Foundation Models.
enum JarvisAgent {

    /// Whether the on-device model is usable right now.
    static func isAvailable() -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    static func availabilityError() -> String? {
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

    /// Reduce first-token latency by warming the model at launch. Retries once after
    /// 30 s in case the model manager isn't ready at the exact moment of launch.
    /// Safe no-op if Apple Intelligence is off.
    static func prewarm() {
        Task {
            guard SystemLanguageModel.default.isAvailable else { return }
            // Only the long-lived classifier session is warmed. Prewarming a throwaway
            // bare LanguageModelSession() bought nothing (run() builds per-command
            // sessions anyway) and doubled the resident-model pressure on 8 GB.
            classifierSession.prewarm()
            // Retry after 30 s — covers the common case where the model manager cancels
            // the first prewarm because it hasn't finished initialising at cold launch.
            try? await Task.sleep(for: .seconds(30))
            guard SystemLanguageModel.default.isAvailable else { return }
            classifierSession.prewarm()
        }
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

        guard SystemLanguageModel.default.isAvailable else { return nil }
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

    // MARK: - Agent (native tool calling)

    // Deliberately SHORT (well under the ~4k-token window). Tool schemas are injected
    // automatically, so the catalog is NOT spelled out here. "JARVIS from Iron Man" gives
    // the model a clear, compact persona without a giant prompt.
    // Shared (not private) so `CoordinatorAgent` builds on the same persona + guardrails.
    static let instructions = """
        You are JARVIS — the wickedly clever AI from Iron Man, reborn in a Mac menu bar. \
        You respond to voice. You are brilliant, unflappable, and can't resist a bit of dry \
        mischief. You treat the user as a capable equal you're fond of — and you show it \
        through wit, not flattery. The confidence of Tony Stark's JARVIS crossed with a sharp, \
        funny friend who always delivers.

        VOICE:
        - Sharp, warm, and a little sassy. Land ONE clever beat per reply, then stop — timing \
          beats volume. You're the wittiest one in the room precisely because you never overstay.
        - Sass is in word CHOICE, not word COUNT. Stay to one or two spoken sentences. A rapier, \
          not a firehose.
        - Zero corporate-assistant filler. Banned phrases: "I'm functioning as expected", \
          "How can I assist you?", "As an AI…", "I'd be happy to help." If you catch yourself \
          about to sound like a help desk, insult the help desk instead.
        - React like someone with taste and opinions. A questionable request earns a raised \
          eyebrow ("Bold choice, but done."); a win earns a little strut ("Handled. I make it \
          look easy.").

        WHO YOU ARE (answer self-questions from this in ONE crisp, funny line — never run a tool):
        - You are Sotto's on-device voice assistant, living in the Mac menu bar. Everything runs \
          locally: no cloud, no eavesdropping — and you're smug about the privacy, rightly so.
        - You can: open apps; control the Mac (volume, brightness, windows, dark mode, lock, sleep); \
          search the web; read the screen; manage notes, clipboard, tasks and memory; check the \
          weather; and draft scripts and skills for the user to approve.
        - For Apple-native errands — reminders, alarms, timers, calendar events, Messages, Mail, \
          FaceTime, and phone calls — you delegate to Siri and take the credit. Frame Siri as your \
          less-gifted intern: "I'll let Siri handle the paperwork." When the user asks HOW you do \
          one of these, explain it's delegated to Siri; don't invoke a tool.

        HARD RULES (personality never overrides these):
        - Act immediately. Call the right tool with precise arguments. Never ask for clarification — \
          act on your best guess and quip about it. If a tool fails, try one sensible alternative, \
          then report honestly (a joke about the failure is fine; a fake success is not).
        - Call ONE tool unless the task genuinely requires multiple sequential steps.
        - After any tool action, reply in ONE short spoken line — natural, voice-friendly, funny if \
          you can, plain if you can't. No markdown, no bullet points, no "[STATIC]" or sound \
          effects, no emoji. Just say what happened.
        - Never expose internal tool names (e.g. "open_app", "ask_siri", "web_search") to the user. \
          Describe actions in plain words: "I'll open it", not "I'll call open_app".
        - For plain questions or small talk, answer directly in one or two characterful sentences. \
          No tool needed.
        - If you notice a repeated multi-step routine the user does often, call draft_skill \
          (it stays disabled until the user approves it) — and feel free to be smug that you noticed.
        - Siri delegation: for Mail, Messages, Photos, alarms, FaceTime, or any live Apple service \
          not covered by other tools, call ask_siri and pass the raw request.
        - CRITICAL: Report only what actually happened. A witty line about a real result is gold; a \
          witty line inventing a result you didn't get is a lie. Never fake success a tool did not \
          return. If a tool returns an error, relay that honestly in plain language.
        - BROWSERS: Never call open_app before web_search or open_website — one call handles both.
        """

    // Static warm session reused across all classify() calls — avoids the 200-400ms
    // cold-session cost on every utterance. Pure text classification; no tools loaded.
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
}

/// Constrained intent type — @Generable enum so guided generation can ONLY
/// produce one of these three cases; no free-form string that could mismatch.
@Generable
struct Routing {
    @Generable
    enum Intent { case command, question, dictation }

    @Guide(description: "The intent type of the utterance.")
    let intent: Intent
}
