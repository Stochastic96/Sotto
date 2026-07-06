import Foundation
import AppKit
import FoundationModels
import SottoCore

// MARK: - FocusSessionTool

/// Start a focused work session: enables DND, quits distracting apps,
/// opens the target project, sets a comfortable volume, and speaks a
/// JARVIS-style confirmation in Hindi/English.
struct FocusSessionTool: Tool {
    let name = "start_focus_session"
    let description = "Start a focused work session: enables Do Not Disturb, quits distracting apps (Twitter, Discord, Slack, Messages), opens the specified project, and sets volume to 40%."
    /// Injectable volume/brightness control; defaults to the live impl.
    let system: any SystemControlling = LiveSystemControl()
    /// Injectable usage recorder; defaults to the shared CommandLearner.
    let recorder: any CommandRecording = CommandLearner.shared

    @Generable
    struct Arguments {
        @Guide(description: "The project name to open (e.g. 'Xcode') or an absolute path if it contains '/'.")
        let project: String
        @Guide(description: "Session duration in minutes. Default is '25' if not specified.")
        let minutes: String
    }

    func call(arguments: Arguments) async throws -> String {
        Task { await recorder.recordToolCall(toolName: name, arguments: arguments) }
        let mins = arguments.minutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "25"
            : arguments.minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = arguments.project.trimmingCharacters(in: .whitespacesAndNewlines)

        // a) Enable DND via AppleScript
        _ = CommandEngine.runCommandNatively(
            "osascript -e 'tell application \"System Events\" to set doNotDisturb of appearance preferences to true'"
        )

        // b) Quit distracting apps
        let distractingApps = ["Twitter", "Discord", "Slack", "Messages"]
        for app in distractingApps {
            _ = CommandEngine.runCommandNatively(
                "osascript -e 'tell application \"\(app)\" to quit'"
            )
        }

        // c) Open project: path if it contains "/", else open by name
        if project.contains("/") {
            _ = CommandEngine.runCommandNatively("open \"\(project)\"")
        } else if !project.isEmpty {
            _ = CommandEngine.runCommandNatively("open -a \"\(project)\"")
        }

        // d) Set volume to 40%
        _ = system.setVolume(40)

        // e) Speak confirmation
        let message = "Focus session started, मिस्टर लॉर्ड. \(mins) minutes, no distractions."
        await MainActor.run { AppController.shared?.speak(message) }

        // f) Return summary
        let summary = "Focus session: \(mins) min\(project.isEmpty ? "" : " on \(project)"). DND enabled, distractions quit, volume at 40%."
        await MainActor.run { AppController.shared?.showHUD("Focus Mode ON") }
        return summary
    }
}

// MARK: - EndWorkdayTool

/// Wrap up the workday: checks git status, summarises today's accomplishments
/// using the on-device model, disables DND, saves a journal entry, and speaks
/// the summary aloud.
struct EndWorkdayTool: Tool {
    let name = "end_workday"
    let description = "End the workday: checks git status, summarises today's accomplishments with the on-device model, disables Do Not Disturb, and saves a journal entry."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        // a) Git status in workspace
        let workspacePath = SettingsController.workspacePath
        let gitStatus = CommandEngine.runCommandNatively(
            "git -C \(workspacePath) status --short"
        )

        // b) Recent accomplishments from journal
        let recentActivity = TaskJournal.recent(limit: 10)

        // c) Summarise using Foundation Models
        let inputText = """
        Today's activity log:
        \(recentActivity)

        Git status:
        \(gitStatus.isEmpty ? "No pending changes." : gitStatus)

        Summarise the above in 1-2 sentences as a workday wrap-up, in first person, concisely.
        """

        var summary: String
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: inputText)
            summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty {
                summary = "Workday complete. \(recentActivity.isEmpty ? "No logged activity today." : "Activity logged.")"
            }
        } catch {
            summary = "Workday wrapped up, मिस्टर लॉर्ड. Git: \(gitStatus.isEmpty ? "clean" : "changes pending")."
        }

        // d) Disable DND
        _ = CommandEngine.runCommandNatively(
            "osascript -e 'tell application \"System Events\" to set doNotDisturb of appearance preferences to false'"
        )

        // e) Save to semantic memory
        SemanticMemory.remember(summary, kind: "journal")

        // f) Speak the summary (copy to let to avoid Swift 6 captured-var warning)
        let spokenSummary = summary
        await MainActor.run { AppController.shared?.speak(spokenSummary) }
        await MainActor.run { AppController.shared?.showHUD("Workday Ended") }

        // g) Return summary
        return summary
    }
}

// MARK: - WorkspaceSwitchTool

/// Switch the desktop environment to a named workflow mode.
/// Each mode arranges apps, sets brightness/volume, and toggles DND
/// to match the activity.
struct WorkspaceSwitchTool: Tool {
    let name = "switch_workspace"
    let description = "Switch the desktop environment to a workflow mode: development, writing, presentation, or entertainment. Each mode opens the right apps and configures volume, brightness, and Do Not Disturb."
    /// Injectable volume/brightness control; defaults to the live impl.
    let system: any SystemControlling = LiveSystemControl()
    /// Injectable usage recorder; defaults to the shared CommandLearner.
    let recorder: any CommandRecording = CommandLearner.shared

    @Generable
    struct Arguments {
        @Guide(description: "The workspace mode to activate. Must be one of: development, writing, presentation, or entertainment.")
        let mode: String
    }

    func call(arguments: Arguments) async throws -> String {
        Task { await recorder.recordToolCall(toolName: name, arguments: arguments) }
        let mode = arguments.mode.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {

        case "development":
            // Open Xcode, Terminal, open workspace path in Finder
            _ = CommandEngine.runCommandNatively("open -a Xcode")
            _ = CommandEngine.runCommandNatively("open -a Terminal")
            let workspacePath = SettingsController.workspacePath
            _ = CommandEngine.runCommandNatively("open \"\(workspacePath)\"")
            // Disable DND so build notifications come through
            _ = CommandEngine.runCommandNatively(
                "osascript -e 'tell application \"System Events\" to set doNotDisturb of appearance preferences to false'"
            )
            let msg = "Development workspace ready, मिस्टर लॉर्ड. Xcode, Terminal, और Finder सब set है। Code करो, भौकाल मचाओ!"
            await MainActor.run { AppController.shared?.speak(msg) }
            await MainActor.run { AppController.shared?.showHUD("Dev Mode") }
            return "Development mode: Xcode + Terminal + Finder opened, DND off."

        case "writing":
            // Open Notes, close Xcode and Terminal, lower brightness, enable DND
            _ = CommandEngine.runCommandNatively("open -a Notes")
            _ = CommandEngine.runCommandNatively(
                "osascript -e 'tell application \"Xcode\" to quit'"
            )
            _ = CommandEngine.runCommandNatively(
                "osascript -e 'tell application \"Terminal\" to quit'"
            )
            _ = system.setBrightness(0.35)
            _ = CommandEngine.runCommandNatively(
                "osascript -e 'tell application \"System Events\" to set doNotDisturb of appearance preferences to true'"
            )
            let msg = "Writing mode on, मिस्टर लॉर्ड. Notes खुली है, distractions गई, brightness कम की। अब लिखो!"
            await MainActor.run { AppController.shared?.speak(msg) }
            await MainActor.run { AppController.shared?.showHUD("Writing Mode") }
            return "Writing mode: Notes opened, Xcode/Terminal quit, brightness lowered, DND enabled."

        case "presentation":
            // Enable DND, max brightness, close non-essential apps, open Keynote
            _ = CommandEngine.runCommandNatively(
                "osascript -e 'tell application \"System Events\" to set doNotDisturb of appearance preferences to true'"
            )
            _ = system.setBrightness(1.0)
            let appsToClose = ["Xcode", "Terminal", "Slack", "Discord", "Messages", "Mail"]
            for app in appsToClose {
                _ = CommandEngine.runCommandNatively(
                    "osascript -e 'tell application \"\(app)\" to quit'"
                )
            }
            _ = CommandEngine.runCommandNatively("open -a Keynote")
            let msg = "Presentation mode ready, मिस्टर लॉर्ड. Keynote open है, brightness full, सब distractions बंद। Stage is yours!"
            await MainActor.run { AppController.shared?.speak(msg) }
            await MainActor.run { AppController.shared?.showHUD("Presentation Mode") }
            return "Presentation mode: DND enabled, brightness maxed, distracting apps quit, Keynote opened."

        case "entertainment":
            // Disable DND, open Spotify, set volume 70%, open browser
            _ = CommandEngine.runCommandNatively(
                "osascript -e 'tell application \"System Events\" to set doNotDisturb of appearance preferences to false'"
            )
            _ = CommandEngine.runCommandNatively("open -a Spotify")
            _ = system.setVolume(70)
            _ = CommandEngine.runCommandNatively("open -a Safari")
            let msg = "Entertainment mode on, मिस्टर लॉर्ड. Spotify चालू, volume 70, browser ready। Chill मारो भाई!"
            await MainActor.run { AppController.shared?.speak(msg) }
            await MainActor.run { AppController.shared?.showHUD("Entertainment Mode") }
            return "Entertainment mode: DND disabled, Spotify opened, volume at 70%, browser opened."

        default:
            return "Unknown workspace mode '\(arguments.mode)'. Use one of: development, writing, presentation, entertainment."
        }
    }
}

