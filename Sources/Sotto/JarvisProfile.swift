import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Gated by SOTTO_FM27 because the macOS 27 FoundationModels APIs (DynamicProfile, Profile,
// GenerationOptions.ToolCallingMode) require the Swift 6.4 toolchain. The currently
// installed Command Line Tools / Xcode ship Swift 6.3.2, which cannot see these symbols even
// though the SDK declares them — so the flag stays OFF until the toolchain updates, and the
// Coordinator uses its hand-built macOS 26 session path. Flip it on in Package.swift then.
#if canImport(FoundationModels) && SOTTO_FM27
/// macOS 27+: expresses Jarvis's lanes as a native `LanguageModelSession.DynamicProfile`.
/// Instructions, tools, temperature, and tool-calling mode all switch by lane — so the chat
/// lane can FORBID tools (no accidental action on small talk) and the big-job lane can
/// REQUIRE `start_long_task`, things the plain per-turn session can't enforce. On macOS 26
/// the Coordinator falls back to building the session by hand (see `CoordinatorAgent`).
@available(macOS 27.0, *)
struct JarvisProfile: LanguageModelSession.DynamicProfile {
    enum Mode: String { case chat, quick, bigJob }

    let mode: Mode
    let instructions: String
    let routedTools: [any Tool]

    private var escalationTools: [any Tool] {
        [DelegateScriptingExecutorTool(), DelegateWebResearcherTool(),
         DelegateOSControlTool(), StartLongTaskTool()]
    }

    var body: some LanguageModelSession.DynamicProfile {
        switch mode {
        case .chat:
            // Small talk: warm, brief, and tools off so nothing fires by accident.
            LanguageModelSession.Profile {
                Instructions(instructions + "\n\nThis is small talk — reply warmly in ONE short line and use no tools.")
            }
            .toolCallingMode(GenerationOptions.ToolCallingMode.disallowed)
            .temperature(0.7)
        case .bigJob:
            // A large repetitive job: narrow to the background-job tool and require it.
            LanguageModelSession.Profile {
                Instructions(instructions + "\n\nThis is a large repetitive job. Call start_long_task with the full goal in plain language.")
                ([StartLongTaskTool()] as [any Tool])
            }
            .toolCallingMode(GenerationOptions.ToolCallingMode.required)
            .temperature(0.2)
        case .quick:
            // The everyday lane: the routed native tools plus the escalation handoffs.
            LanguageModelSession.Profile {
                Instructions(instructions)
                routedTools
                (escalationTools as [any Tool])
            }
            .temperature(0.3)
        }
    }

    /// High-precision lane pick. Defaults to `.quick`; only diverts on clear small talk or
    /// clear bulk phrasing, so a genuine command is never starved of tools.
    static func classify(_ input: String) -> Mode {
        let t = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let greetings = ["hi", "hii", "hey", "hello", "yo", "how are you", "how's it going",
                         "hows it going", "good morning", "good afternoon", "good evening",
                         "good night", "thanks", "thank you", "what's up", "whats up", "sup",
                         "you there", "are you there", "good to see you"]
        if t.count < 40, greetings.contains(where: { t == $0 || t.hasPrefix($0 + " ") || t.hasPrefix($0 + ",") }) {
            return .chat
        }

        let bulkMarkers = ["all promotional", "all the promotional", "all my promotional",
                           "delete all", "clean up my inbox", "clean my inbox", "every promotional",
                           "all marketing", "all newsletter", "all the newsletter", "bulk"]
        if bulkMarkers.contains(where: { t.contains($0) }) {
            return .bigJob
        }
        return .quick
    }
}
#endif
