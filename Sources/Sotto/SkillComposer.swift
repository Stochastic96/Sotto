import Foundation
import AppKit

// ── SkillComposer ─────────────────────────────────────────────────────────────
// Dynamically composes multi-step workflows from primitive skills using
// Foundation Models as the planner layer. Available on macOS 14+; the
// Foundation Models planning path is gated to macOS 26+.

#if canImport(FoundationModels)
import FoundationModels

// ── Generable types for the planner ──────────────────────────────────────────

@available(macOS 26.0, *)
@Generable
struct WorkflowStep {
    @Guide(description: "Tool name to call, e.g. 'morning_brief', 'start_focus_session', 'switch_workspace'")
    let toolName: String
    @Guide(description: "Primary argument for the tool, or empty string")
    let argument: String
    @Guide(description: "One sentence explaining why this step is included")
    let reason: String
}

@available(macOS 26.0, *)
@Generable
struct WorkflowPlan {
    @Guide(description: "2-5 steps to complete the user's goal. Pick from available tools only.")
    let steps: [WorkflowStep]
    @Guide(description: "One sentence telling the user what you're about to do.")
    let announcement: String
}

// ── ComposedWorkflowTool ──────────────────────────────────────────────────────

@available(macOS 26.0, *)
struct ComposedWorkflowTool: Tool {
    let name = "compose_workflow"
    let description = "Plan and execute a multi-step workflow for a high-level user goal, such as 'start my workday' or 'set up dev environment'."

    @Generable
    struct Arguments {
        @Guide(description: "The high-level user goal to accomplish, e.g. 'set up my dev environment' or 'I am about to start work'.")
        let goal: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await SkillComposer.shared.compose(goal: arguments.goal)
    }
}

#endif // canImport(FoundationModels)

// ── SkillComposer actor ───────────────────────────────────────────────────────

@available(macOS 14.0, *)
actor SkillComposer {
    static let shared = SkillComposer()

    // Available tool names the planner may select from.
    private let availableTools = [
        "morning_brief", "start_focus_session", "end_workday", "switch_workspace",
        "organize_downloads", "find_large_files", "generate_git_commit",
        "get_system_status", "get_ram_status", "get_weather",
        "run_skill", "recall_history", "search_memory"
    ]

    // Compose a multi-step workflow for the given goal.
    // Returns a completion message suitable for speaking to the user.
    func compose(goal: String) async -> String {
        // Cached plan? Replay the saved steps with zero tokens instead of re-planning.
        // Composing a workflow is the single most expensive Foundation Models call in the
        // app; the plan for "set up my dev environment" doesn't change between runs.
        if let cached = WorkflowPlanCache.load(goal), !cached.isEmpty {
            print("[COMPOSER] Cache hit for '\(goal)' — replaying \(cached.count) steps, 0 tokens.")
            await MainActor.run {
                AppController.shared?.showHUD("Replaying saved workflow…")
                AppController.shared?.speak("Running your saved workflow.")
            }
            for step in cached {
                await executeStep(toolName: step.toolName, argument: step.argument)
            }
            let summary = "Workflow complete (cached): \(cached.count) steps for \"\(goal)\"."
            await EventBus.shared.emit(.missionCompleted(id: "compose_workflow", summary: summary))
            return summary
        }

#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await composeWithFoundationModels(goal: goal)
        }
#endif
        return "Workflow composition requires macOS 26 or later."
    }

    // Execute a single workflow step by dispatching a SottoIncomingCommand notification.
    private func executeStep(toolName: String, argument: String) async {
        let text = argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? toolName
            : "\(toolName) \(argument)"

        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("SottoIncomingCommand"),
                object: nil,
                userInfo: ["text": text]
            )
        }

        // Give each step time to complete before triggering the next.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func composeWithFoundationModels(goal: String) async -> String {
        let session = LanguageModelSession()

        let prompt = """
        You are JARVIS, planning a workflow. Available tools: \(availableTools.joined(separator: ", ")).
        User goal: \(goal)
        Return 2-4 steps using ONLY available tool names. Prefer fewer steps.
        """

        do {
            let plan = try await session.respond(
                to: prompt,
                generating: WorkflowPlan.self
            )

            let workflowPlan = plan.content

            // Cache the plan so the next identical goal replays without the model.
            WorkflowPlanCache.save(goal, steps: workflowPlan.steps.map {
                CachedStep(toolName: $0.toolName, argument: $0.argument)
            })

            // Announce what we are about to do.
            await MainActor.run {
                AppController.shared?.showHUD(workflowPlan.announcement)
                AppController.shared?.speak(workflowPlan.announcement)
            }

            // Execute each step in sequence.
            for step in workflowPlan.steps {
                await executeStep(toolName: step.toolName, argument: step.argument)
            }

            let summary = "Workflow complete: \(workflowPlan.steps.count) steps executed for \"\(goal)\"."
            await EventBus.shared.emit(.missionCompleted(id: "compose_workflow", summary: summary))
            return summary

        } catch {
            let message = "Workflow planning failed: \(error.localizedDescription)"
            await MainActor.run {
                AppController.shared?.showHUD("Workflow planning failed.")
            }
            return message
        }
    }
#endif
}

// MARK: - WorkflowPlanCache
//
// Persists composed workflow plans keyed by a normalized goal, so a repeated goal
// replays its saved steps without another Foundation Models planning call.

struct CachedStep: Codable, Sendable {
    let toolName: String
    let argument: String
}

enum WorkflowPlanCache {
    private static let defaultsKey = "sotto_workflow_plan_cache"

    /// Lowercased, whitespace-collapsed goal so "Set up   my Dev Environment" and
    /// "set up my dev environment" share one cache entry.
    static func normalized(_ goal: String) -> String {
        goal.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func load(_ goal: String) -> [CachedStep]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([String: [CachedStep]].self, from: data) else { return nil }
        return dict[normalized(goal)]
    }

    static func save(_ goal: String, steps: [CachedStep]) {
        var dict: [String: [CachedStep]] = [:]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let existing = try? JSONDecoder().decode([String: [CachedStep]].self, from: data) {
            dict = existing
        }
        dict[normalized(goal)] = steps
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
