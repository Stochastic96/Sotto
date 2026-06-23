import Foundation
import AppKit
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - MissionOrchestrator
//
// Hybrid skill + Apple Intelligence mission runner.
//
// Big tasks that need multiple steps go here instead of the single-turn agent.
// Apple Intelligence plans the step sequence; native skills execute each step
// deterministically (0 tokens); Apple Intelligence summarises the result.
//
// Everything is broadcast on EventBus so the HUD and TTS stay live throughout.
//
// Example goals:
//   "organise my downloads, summarise what was cleared, and save a note"
//   "check my email, find action items, and add them to my reminders"
//   "read the screen, explain what I'm looking at, and copy the summary"

// MARK: - Mission model

struct Mission: Codable, Sendable {
    enum Status: String, Codable { case planned, running, done, failed }

    let id: String
    let goal: String
    var steps: [Step]
    var status: Status
    var summary: String
    let createdAt: Date

    struct Step: Codable, Sendable {
        enum Kind: String, Codable {
            case skill          // native Swift — 0 tokens
            case intelligence   // Foundation Models sub-prompt
        }
        let index: Int
        let label: String       // shown in HUD
        let kind: Kind
        let action: String      // skill key or prompt fragment
        var result: String?
        var done: Bool
    }
}

// MARK: - Mission step registry
// Maps skill keys to native closures so the orchestrator never touches the model for these.

enum MissionSkill {
    typealias Handler = @Sendable (String) async -> String

    // Register all native skills here — grow this list without touching the planner.
    static let registry: [String: Handler] = [
        "organize_downloads":    { _ in
            if #available(macOS 26.0, *) {
                return (try? await FileOrganizerTool().call(arguments: .init())) ?? "Organizer failed."
            }
            return "Requires macOS 26."
        },
        "read_screen":           { _ in await AppController.shared?.ocrScreen() ?? "Screen unreadable." },
        "copy_to_clipboard":     { text in
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return "Copied to clipboard."
        },
        "paste":                 { _ in
            await MainActor.run { AppController.shared?.pasteCurrentClipboard() }
            return "Pasted."
        },
        "select_all":            { _ in
            await MainActor.run { AppController.shared?.selectAll() }
            return "Selected all text."
        },
        "undo":                  { _ in
            await MainActor.run { _ = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            return "Undone."
        },
        "redo":                  { _ in
            await MainActor.run { _ = NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            return "Redone."
        },
        "create_note":           { content in
            let ok = await MainActor.run { NativeSystemOrchestrator.createNote(content) }
            return ok ? "Note created in Notes." : "Note creation failed."
        },
        "open_reminders":        { _ in
            await MainActor.run { _ = CommandEngine.openApp(named: "Reminders") }
            return "Reminders opened."
        },
        "empty_trash":           { _ in
            await MainActor.run { NativeSystemOrchestrator.emptyTrash() }
            return "Trash emptied."
        },
        "lock_screen":           { _ in
            await MainActor.run { NativeSystemOrchestrator.lockScreen() }
            return "Screen locked."
        },
        "system_status":         { _ in
            let bat  = SystemDiagnostics.getBatteryPercentage()
            let wifi = SystemDiagnostics.getWifiSSID()
            let disk = SystemDiagnostics.getFreeDiskSpace()
            return "Battery \(bat), Wi-Fi \(wifi), Disk \(disk)."
        },
    ]
}

// MARK: - Orchestrator actor

@available(macOS 26.0, *)
actor MissionOrchestrator {
    static let shared = MissionOrchestrator()

    private var activeMission: Mission?

    // MARK: - Public API

    /// Run a multi-step goal. Returns when all steps are done or on first failure.
    func run(goal: String) async {
        let id = UUID().uuidString.prefix(8).lowercased()
        print("[MISSION] Starting: \(goal)")
        await EventBus.shared.emit(.missionStarted(id: String(id), goal: goal))

        // 1. Plan steps using Apple Intelligence
        let steps = await planSteps(for: goal, id: String(id))
        var mission = Mission(id: String(id), goal: goal, steps: steps,
                              status: .running, summary: "", createdAt: Date())
        activeMission = mission
        await EventBus.shared.emit(.suggestionReady(message: "Mission: \(steps.count) steps planned", command: nil))

        // 2. Execute each step
        var stepResults: [String] = []
        for i in steps.indices {
            let step = steps[i]
            let preview = "[\(i+1)/\(steps.count)] \(step.label)…"
            await MainActor.run { AppController.shared?.showHUD(preview) }
            print("[MISSION] Step \(i+1): \(step.label)")

            let result: String
            switch step.kind {
            case .skill:
                if let handler = MissionSkill.registry[step.action] {
                    result = await handler(stepResults.last ?? "")
                } else {
                    result = await runViaAgent(step.action, context: stepResults.last ?? "")
                }
            case .intelligence:
                // Build prompt with accumulated context from prior steps
                let ctx = stepResults.isEmpty ? "" : "\nContext from prior steps:\n\(stepResults.joined(separator: "\n"))"
                result = await runIntelligence(step.action + ctx)
            }

            mission.steps[i].result = result
            mission.steps[i].done   = true
            stepResults.append(result)
            print("[MISSION] Step \(i+1) done: \(result.prefix(80))")
        }

        // 3. Summarise results with Apple Intelligence
        let summary = await summariseResults(goal: goal, results: stepResults)
        mission.summary = summary
        mission.status  = .done
        activeMission   = mission

        await EventBus.shared.emit(.missionCompleted(id: String(id), summary: summary))
        await MainActor.run {
            AppController.shared?.showHUD("✅ \(summary.prefix(100))")
            AppController.shared?.speak(summary)
        }
        print("[MISSION] Completed: \(summary)")
    }

    // MARK: - Planning (Apple Intelligence breaks goal → steps)

    private func planSteps(for goal: String, id: String) async -> [Mission.Step] {
        // Try Apple Intelligence first; fall back to heuristic parser
        if let steps = await planWithIntelligence(goal) { return steps }
        return heuristicPlan(goal, id: id)
    }

    #if canImport(FoundationModels)
    private func planWithIntelligence(_ goal: String) async -> [Mission.Step]? {
        guard #available(macOS 26.0, *) else { return nil }

        let availableSkills = MissionSkill.registry.keys.sorted().joined(separator: ", ")
        let prompt = """
        Break this goal into 2–5 ordered steps. For each step, output one line:
        skill|<skill_key>|<label>  — if it matches a skill in: \(availableSkills)
        intelligence|<prompt>|<label>  — for reasoning, summarising, or anything else

        Goal: \(goal)
        Output only the step lines, nothing else.
        """

        let session = LanguageModelSession()
        guard let raw = try? await session.respond(to: prompt).content else { return nil }

        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var steps: [Mission.Step] = []
        for (i, line) in lines.enumerated() {
            let parts = line.components(separatedBy: "|")
            guard parts.count == 3 else { continue }
            let kind: Mission.Step.Kind = parts[0].trimmingCharacters(in: .whitespaces) == "skill" ? .skill : .intelligence
            steps.append(.init(index: i, label: parts[2].trimmingCharacters(in: .whitespaces),
                                kind: kind, action: parts[1].trimmingCharacters(in: .whitespaces),
                                result: nil, done: false))
        }
        return steps.isEmpty ? nil : steps
    }
    #else
    private func planWithIntelligence(_ goal: String) async -> [Mission.Step]? { nil }
    #endif

    // Heuristic fallback — keyword matching without the model
    private func heuristicPlan(_ goal: String, id: String) -> [Mission.Step] {
        let lower = goal.lowercased()
        var steps: [Mission.Step] = []
        var idx = 0

        let add: (String, Mission.Step.Kind, String) -> Void = { label, kind, action in
            steps.append(.init(index: idx, label: label, kind: kind, action: action, result: nil, done: false))
            idx += 1
        }

        if lower.contains("download") || lower.contains("organis") || lower.contains("clean file") {
            add("Organise downloads", .skill, "organize_downloads")
        }
        if lower.contains("screen") || lower.contains("read") || lower.contains("ocr") {
            add("Read screen", .skill, "read_screen")
        }
        if lower.contains("system") || lower.contains("status") || lower.contains("battery") {
            add("System status", .skill, "system_status")
        }
        if lower.contains("summarise") || lower.contains("summarize") || lower.contains("summary") {
            add("Summarise results", .intelligence, "Summarise the following results concisely in 2–3 sentences.")
        }
        if lower.contains("note") || lower.contains("save") || lower.contains("write") {
            add("Save note", .skill, "create_note")
        }
        if lower.contains("copy") { add("Copy to clipboard", .skill, "copy_to_clipboard") }
        if lower.contains("trash") || lower.contains("empty") { add("Empty trash", .skill, "empty_trash") }

        // Default: run via the Jarvis agent as a single step
        if steps.isEmpty {
            steps.append(.init(index: 0, label: goal.prefix(50).description,
                               kind: .intelligence, action: goal, result: nil, done: false))
        }
        return steps
    }

    // MARK: - Execution helpers

    private func runViaAgent(_ prompt: String, context: String) async -> String {
        guard #available(macOS 26.0, *) else { return "Apple Intelligence unavailable." }
        let full = context.isEmpty ? prompt : "\(prompt)\n\nContext: \(context)"
        return (try? await JarvisAgent.run(full)) ?? "Agent unavailable."
    }

    private func runIntelligence(_ prompt: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession()
            return (try? await session.respond(to: prompt).content) ?? "No response."
        }
        #endif
        return await runViaAgent(prompt, context: "")
    }

    // MARK: - Summary (Apple Intelligence condenses all results into one spoken line)

    private func summariseResults(goal: String, results: [String]) async -> String {
        let combined = results.enumerated().map { "Step \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        let prompt = "The user asked: \"\(goal)\". Here are the results:\n\(combined)\n\nGive a single spoken-word summary in one sentence, past tense."
        return await runIntelligence(prompt)
    }
}

// MARK: - AppController helpers for Apple commands (used by MissionSkill registry)

extension AppController {
    // ⌘V into the last active app
    func pasteCurrentClipboard() {
        Task {
            _ = await KeySimulator.simulate(key: "v", cmd: true, shift: false, opt: false, ctrl: false)
        }
    }

    // ⌘A — select all in last active app
    func selectAll() {
        Task {
            _ = await KeySimulator.simulate(key: "a", cmd: true, shift: false, opt: false, ctrl: false)
        }
    }

    func ocrScreen() async -> String {
        return await CommandEngine.performScreenOCR()
    }
}
