import Foundation
import FoundationModels

/// Expresses Jarvis's lanes as a native `LanguageModelSession.DynamicProfile`
/// (macOS 27+ only — the deployment target for this app). Instructions, tools,
/// temperature, and tool-calling mode all switch by lane — so the chat lane can
/// FORBID tools (no accidental action on small talk) and the big-job lane can
/// REQUIRE `start_long_task`, things a plain per-turn session can't enforce.
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
