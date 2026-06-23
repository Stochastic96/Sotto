import Foundation
import AppIntents

// Exposes Jarvis to the Shortcuts app, Spotlight, and Siri for AUTOMATION (e.g. run Jarvis on a
// schedule, from a hotkey, or as a step in a workflow). These are lightweight — no model is
// loaded here; they hand the request to the already-warm Jarvis brain in the running app.
//
// Intents that use the NotificationCenter path work even when AppController hasn't finished
// bootstrapping — the command will be queued and picked up by HotkeyListener/Transcriber.

// MARK: - 1. Run any Jarvis voice command via Siri/Shortcuts

@available(macOS 26.0, *)
struct RunJarvisCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Jarvis Command"
    static var description = IntentDescription("Run any Jarvis command by speaking it.")

    @Parameter(title: "Command", requestValueDialog: "What should Jarvis do?")
    var command: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("SottoIncomingCommand"),
                object: nil,
                userInfo: ["text": command]
            )
        }
        return .result(value: "Running: \(command)")
    }
}

// MARK: - 2. Morning Brief

@available(macOS 26.0, *)
struct MorningBriefIntent: AppIntent {
    static var title: LocalizedStringResource = "Morning Brief"
    static var description = IntentDescription("Get Jarvis morning briefing with calendar, weather and tasks.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("SottoIncomingCommand"),
                object: nil,
                userInfo: ["text": "morning brief"]
            )
        }
        return .result(value: "Starting morning brief.")
    }
}

// MARK: - 3. Focus Session

@available(macOS 26.0, *)
struct StartFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Focus Session"
    static var description = IntentDescription("Start a focused work session on a project.")

    @Parameter(title: "Project", requestValueDialog: "Which project should I focus on?")
    var project: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("SottoIncomingCommand"),
                object: nil,
                userInfo: ["text": "start focus session on \(project)"]
            )
        }
        return .result(value: "Starting focus session on \(project).")
    }
}

// MARK: - 4. End Workday

@available(macOS 26.0, *)
struct EndWorkdayIntent: AppIntent {
    static var title: LocalizedStringResource = "End Workday"
    static var description = IntentDescription("Wrap up the workday: close open tasks, write a summary, and set DND.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("SottoIncomingCommand"),
                object: nil,
                userInfo: ["text": "end workday"]
            )
        }
        return .result(value: "Ending workday.")
    }
}

// MARK: - 5. Organize Downloads

@available(macOS 26.0, *)
struct OrganizeDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Organize Downloads"
    static var description = IntentDescription("Sort and organize files in the Downloads folder.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("SottoIncomingCommand"),
                object: nil,
                userInfo: ["text": "organize downloads"]
            )
        }
        return .result(value: "Organizing downloads.")
    }
}

// MARK: - 6. Ask Jarvis (freeform — routes through CoordinatorAgent)

@available(macOS 26.0, *)
struct AskJarvisIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Jarvis"
    static var description = IntentDescription("Ask Jarvis to answer a question or do something on your Mac.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Request", requestValueDialog: "What should Jarvis do?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await AppController.shared?.runJarvisRequest(request) ?? "Jarvis isn't running right now."
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

// MARK: - 7. Clean Promotional Email (long-task background job)

@available(macOS 26.0, *)
struct CleanPromotionalEmailIntent: AppIntent {
    static var title: LocalizedStringResource = "Clean Promotional Email"
    static var description = IntentDescription("Move promotional and marketing emails to the Trash, in the background.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = LongTaskEngine.start(goal: "delete all promotional emails from my inbox")
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - Dynamic Skill Entity

@available(macOS 26.0, *)
struct DraftedSkillEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Jarvis Skill"
    static var defaultQuery = DraftedSkillQuery()

    var id: String
    var name: String
    var skillDescription: String
    var trigger: String
    var language: String
    var enabled: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name) (\(enabled ? "Enabled" : "Pending"))",
            subtitle: "\(trigger)"
        )
    }
}

@available(macOS 26.0, *)
struct DraftedSkillQuery: EnumerableEntityQuery {
    func entities(for identifiers: [String]) async throws -> [DraftedSkillEntity] {
        SkillStore.listAll()
            .filter { identifiers.contains($0.name) }
            .map { DraftedSkillEntity(id: $0.name, name: $0.name, skillDescription: $0.description, trigger: $0.trigger, language: $0.language, enabled: $0.enabled) }
    }

    func suggestedEntities() async throws -> [DraftedSkillEntity] {
        SkillStore.listAll().map { DraftedSkillEntity(id: $0.name, name: $0.name, skillDescription: $0.description, trigger: $0.trigger, language: $0.language, enabled: $0.enabled) }
    }

    func allEntities() async throws -> [DraftedSkillEntity] {
        SkillStore.listAll().map { DraftedSkillEntity(id: $0.name, name: $0.name, skillDescription: $0.description, trigger: $0.trigger, language: $0.language, enabled: $0.enabled) }
    }
}

// MARK: - 8. Run Skill

@available(macOS 26.0, *)
struct RunSkillIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Jarvis Skill"
    static var description = IntentDescription("Execute an enabled Jarvis skill script.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Skill")
    var skill: DraftedSkillEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard skill.enabled else {
            return .result(dialog: IntentDialog(stringLiteral: "Skill '\(skill.name)' is not enabled yet. Please enable it first."))
        }
        let reply = SkillStore.runEnabled(skill.name)
        return .result(dialog: IntentDialog(stringLiteral: "Executed skill '\(skill.name)'. Output:\n\(reply)"))
    }
}

// MARK: - 9. List Skills

@available(macOS 26.0, *)
struct ListSkillsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Jarvis Skills"
    static var description = IntentDescription("List all drafted and enabled Jarvis skills.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let skills = SkillStore.listAll()
        if skills.isEmpty {
            return .result(dialog: IntentDialog("There are no drafted or enabled skills yet."))
        }
        let listStr = skills.map { "- \($0.name) (\($0.enabled ? "Enabled" : "Pending approval")): \($0.description)" }.joined(separator: "\n")
        return .result(dialog: IntentDialog(stringLiteral: "Here are your Sotto/Jarvis skills:\n\(listStr)"))
    }
}

// MARK: - Shortcuts / Siri registration

@available(macOS 26.0, *)
struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunJarvisCommandIntent(),
            phrases: [
                "Run Jarvis command",
                "Hey Jarvis \(\.$command)",
                "Ask \(.applicationName) to \(\.$command)"
            ],
            shortTitle: "Run Command",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: MorningBriefIntent(),
            phrases: [
                "Morning brief",
                "Good morning Jarvis",
                "Start my morning brief with \(.applicationName)"
            ],
            shortTitle: "Morning Brief",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: StartFocusSessionIntent(),
            phrases: [
                "Start focus session on \(\.$project)",
                "Focus on \(\.$project)",
                "Start a focus session in \(.applicationName) on \(\.$project)"
            ],
            shortTitle: "Focus Session",
            systemImageName: "brain.head.profile"
        )
        AppShortcut(
            intent: EndWorkdayIntent(),
            phrases: [
                "End my workday",
                "Wrap up work",
                "End workday in \(.applicationName)"
            ],
            shortTitle: "End Workday",
            systemImageName: "moon.stars"
        )
        AppShortcut(
            intent: OrganizeDownloadsIntent(),
            phrases: [
                "Organize my downloads",
                "Sort downloads",
                "Organize downloads with \(.applicationName)"
            ],
            shortTitle: "Organize Downloads",
            systemImageName: "folder.badge.gearshape"
        )
        AppShortcut(
            intent: CleanPromotionalEmailIntent(),
            phrases: [
                "Clean my promo emails with \(.applicationName)",
                "Clean promotional emails with \(.applicationName)",
                "Run promo cleanup in \(.applicationName)"
            ],
            shortTitle: "Clean Promotional Emails",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: RunSkillIntent(),
            phrases: [
                "Run Jarvis skill \(\.$skill)",
                "Execute skill \(\.$skill) in \(.applicationName)"
            ],
            shortTitle: "Run Jarvis Skill",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: ListSkillsIntent(),
            phrases: [
                "List my Jarvis skills",
                "Show my Sotto skills",
                "List enabled skills in \(.applicationName)"
            ],
            shortTitle: "List Jarvis Skills",
            systemImageName: "list.bullet"
        )
    }
}

// Backward-compatible alias so callers that reference SottoShortcuts still compile.
@available(macOS 26.0, *)
typealias SottoShortcuts = JarvisShortcuts
