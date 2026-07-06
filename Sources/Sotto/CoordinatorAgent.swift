import Foundation
import FoundationModels
import SottoCore

@Generable
public struct TurnOutcome: Sendable {
    @Guide(description: "A final response or answer to the user's request. Choose this when you can fulfill the user's intent or have performed the actions. Leave empty if clarifying.")
    public let reply: String?
    
    @Guide(description: "A clarifying question to the user. Choose this when you are genuinely unsure and need to ask the user a question before proceeding. Leave empty if you can reply.")
    public let clarifyingQuestion: String?
}

@Generable
public struct SwiftScript: Sendable {
    @Guide(description: "The complete, valid, compiling raw Swift script body. Do NOT wrap in markdown code fences or include explanations. Only the Swift code itself.")
    public let code: String
}

// MARK: - Delegation Tools

struct DelegateOSControlTool: Tool {
    let name = "delegate_to_os_control"
    let description = "Delegate native macOS control tasks (volume, brightness, power, notes, reminders, calendar) to the OS Control Agent."
    /// Injectable sub-agent; defaults to the warm shared OS Control Agent.
    let agent: any SubAgent = OSControlAgent.shared

    @Generable
    struct Arguments {
        @Guide(description: "The specific OS task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await agent.run(task: arguments.task)
    }
}

struct DelegateWebResearcherTool: Tool {
    let name = "delegate_to_web_researcher"
    let description = "Delegate web search, screen reading, and clicking actions to the Web Researcher Agent."
    /// Injectable sub-agent; defaults to the warm shared Web Researcher Agent.
    let agent: any SubAgent = WebResearcherAgent.shared

    @Generable
    struct Arguments {
        @Guide(description: "The web research task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await agent.run(task: arguments.task)
    }
}

struct DelegateScriptingExecutorTool: Tool {
    let name = "delegate_to_scripting_executor"
    let description = "Delegate complex computational or automation tasks requiring writing and running Swift scripts to the Scripting Executor Agent."
    /// Injectable sub-agent; defaults to the warm shared Scripting Executor Agent.
    let agent: any SubAgent = ScriptingExecutorAgent.shared

    @Generable
    struct Arguments {
        @Guide(description: "The scripting task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await agent.run(task: arguments.task)
    }
}



struct SetScreenElementValueTool: Tool {
    let name = "set_screen_element_value"
    let description = "Set a text value on an input element by its integer ID obtained from read_screen."

    @Generable
    struct Arguments {
        @Guide(description: "The integer ID of the input element.")
        let id: Int
        @Guide(description: "The text value to enter.")
        let value: String
    }

    func call(arguments: Arguments) async throws -> String {
        let success = ScreenParser.performSetValue(id: arguments.id, value: arguments.value)
        return success ? "Successfully set value on element with ID \(arguments.id)." : "Failed to set value on element with ID \(arguments.id)."
    }
}

// MARK: - CoordinatorAgent

/// Sentinel prefix the model emits when it needs to ask the user a clarifying question.
/// `AppController` detects it, speaks the question, and re-opens the mic for one follow-up.
public let kClarificationPrefix = "ASK:"

/// The Jarvis "front door". One warm Apple Foundation Models session carries the most
/// relevant native tools (the fast single-hop lane — the framework runs the tool-calling
/// loop itself) plus escalation tools that hand off to specialized sub-agents only when a task
/// genuinely needs running code, deep screen-driving, or compound OS work. Large repetitive
/// jobs are kicked off as background `start_long_task`s.
/// Actor isolation ensures the mutable `session` state is never raced — a second Jarvis
/// command arriving before the first completes cannot corrupt the in-flight session.
public actor CoordinatorAgent {
    // Test-only toggle, flipped once from single-threaded test setup, never mid-flight.
    nonisolated(unsafe) public static var isMockMode = false

    // Spoken/HUD confirmation when a bigJob has been handed to the background engine.
    // Kept task-agnostic on purpose — a hardcoded "cleaning up your inbox" line misdescribes
    // every non-inbox bulk job (rename downloads, organize photos, …).
    private static let backgroundJobReply = "On it — I'll take care of that in the background and let you know when it's done."

    // Retained across a clarification round-trip so the follow-up answer lands in the same
    // multi-turn transcript. Actor isolation replaces the need for explicit locking.
    private var session: LanguageModelSession?
    public var isWarm: Bool { session != nil }

    public func unload() {
        if session != nil {
            Task { @MainActor in MemoryLedger.shared.recordEviction() }
        }
        session = nil
    }

    /// Shared instance — used by `MicrotaskQueue` and `AppController` so background tasks
    /// don't each pay a fresh session-init cost.
    public static let shared = CoordinatorAgent()
    public init() {}

    /// Bootstrap the CommandLearner hint cache. The plain-session prewarm was removed:
    /// actual turns use `LanguageModelSession(profile:)`, not a bare session, so warming
    /// a plain session wastes ANE time and contributes to CriticalMemoryPressure bursts.
    public static func prewarm() {
        Task { await CommandLearner.shared.bootstrap() }
    }

    /// Persona + guardrails (shared with `JarvisAgent`) plus the lane guidance, the learned
    /// user profile, and the memories most relevant to THIS utterance. Rebuilt per turn so a
    /// freshly-taught preference (or a just-recalled memory) is reflected.
    private func buildInstructions(for userInput: String, conversation: String? = nil) -> String {
        // Kept clean and structured: the on-device model has a large context window,
        // but keeping instructions focused ensures better tool selection accuracy.
        var instr = JarvisAgent.instructions + """


        Lanes: chat/greetings → one warm line, no tool. Writing (poems, emails, paragraphs) → write the text yourself, never delegate_to_scripting_executor. General questions → answer briefly, or web_search/open_website for current info. Big repetitive jobs → start_long_task. If truly ambiguous, reply exactly "\(kClarificationPrefix) <one short question>" and nothing else.
        """
        if let profile = UserProfile.summary() {
            instr += "\n\nWhat you know about the user:\n\(profile)"
        }
        if let conversation {
            instr += "\n\n\(conversation)"
        }
        let recalled = SemanticMemory.recall(for: userInput, limit: 3)
        if !recalled.isEmpty {
            instr += "\n\nRelevant memories (use only if helpful; ignore if not):\n"
                + recalled.map { "- \($0)" }.joined(separator: "\n")
        }
        return instr
    }

    public func handleTurn(userInput: String, isFollowUp: Bool = false) async throws -> String {
        // Attribute tool calls fired during this turn. Deliberately never cleared —
        // tools record via fire-and-forget tasks that can land after the turn returns;
        // the next turn simply overwrites the utterance.
        await CommandLearner.shared.setCurrentUtterance(userInput)
        if Self.isMockMode {
            print("[MOCK-COORDINATOR] Starting mock turn loop for user input: '\(userInput)'")
            var currentInput = userInput
            var turnOutput = ""

            // Loop through at least two turns
            for turn in 1...2 {
                print("[MOCK-COORDINATOR] Loop Turn \(turn) starting with: \(currentInput)")
                if turn == 1 {
                    // Turn 1: Screen parser
                    let screenMarkup = ScreenParser.captureActiveWindowTree()
                    print("[MOCK-COORDINATOR] Screen Parser output (\(screenMarkup.count) chars)")
                    turnOutput = "Parsed screen tree successfully."
                    currentInput = "Screen content analyzed. Proceed to compute disk space."
                } else if turn == 2 {
                    // Turn 2: Scripting executor
                    print("[MOCK-COORDINATOR] Delegating script execution task...")
                    let scriptResult = await ScriptingExecutorAgent.shared.run(task: "compute total disk space")
                    print("[MOCK-COORDINATOR] Scripting Executor response: \(scriptResult)")
                    turnOutput = scriptResult
                }
            }

            // Turn 3: final ingestion
            print("[MOCK-COORDINATOR] Final Turn: ingesting back script result: \(turnOutput)")
            return "Final Result: The Swift script ran successfully. \(turnOutput)"
        }

        // Follow-up answer to a clarifying question: continue the SAME session.
        if isFollowUp, let session = self.session {
            let response = try await session.respond(to: userInput, generating: TurnOutcome.self, options: GenerationOptions(temperature: 0.3))
            return Self.reply(from: response.content)
        }

        let conversation = await ConversationMemory.shared.digest()
        let instructions = buildInstructions(for: userInput, conversation: conversation)
        let routed = Array(await JarvisToolbox.routed(for: userInput).prefix(5))

        // Drive the session manually by constructing LanguageModelSession with custom instructions and tools
        // matching the active lane. Bypasses LanguageModelSession(profile:) to prevent dyld Symbol not found crashes.
        let mode = JarvisProfile.classify(userInput)
        print("[COORDINATOR] Lane: \(mode.rawValue)  (routed: \(routed.map { $0.name }.joined(separator: ", ")))")
        
        // BigJob lane has its own idempotent flow (it must start the background job exactly
        // once), so it never shares the chat/quick session path below.
        if mode == .bigJob {
            return await runBigJobTurn(userInput: userInput, instructions: instructions)
        }

        let session: LanguageModelSession
        let temperature: Double
        if mode == .chat {
            // Chat lane: warm, brief, no tools.
            session = LanguageModelSession(instructions: instructions + "\n\nThis is small talk — reply warmly in ONE short line and use no tools.")
            temperature = 0.7
        } else {
            // Quick lane: native routed tools + escalation tools.
            let escalationTools: [any Tool] = [DelegateScriptingExecutorTool(), DelegateWebResearcherTool(), DelegateOSControlTool(), StartLongTaskTool()]
            session = LanguageModelSession(tools: routed + escalationTools, instructions: instructions)
            temperature = 0.3
        }
        self.session = session

        do {
            // 40-second hard timeout: the tool-calling loop has no built-in cycle limit —
            // without maximumResponseTokens AND a timeout, a model with no city for
            // get_weather can loop asking for clarification indefinitely.
            let opts = GenerationOptions(temperature: temperature, maximumResponseTokens: 512)
            let outcome: TurnOutcome = try await withTimeout(seconds: 40, errorDomain: "JarvisTurn", errorDescription: "Jarvis turn timed out after 40s") {
                try await session.respond(to: userInput, generating: TurnOutcome.self, options: opts).content
            }
            let reply = Self.reply(from: outcome)
            recordLearned(phrase: userInput, reply: reply)
            return reply
        } catch {
            print("[COORDINATOR] Jarvis turn failed (\(error.localizedDescription)); retrying tool-free.")
            self.session = nil
            await Task.yield()
            // Log feedback for session failures so Apple can improve model stability.
            JarvisDiagnostics.record(
                session: self.session,
                error: error,
                input: userInput,
                description: "Per-lane session failed or timed out",
                category: .toolCallLoop
            )
            // Retry once with a minimal, tool-free session — sheds context and re-responds
            // (Apple's own guidance for a context-window overrun) so a transient hiccup or
            // timeout doesn't leave Jarvis silent for the turn.
            let lean = LanguageModelSession(instructions: JarvisAgent.instructions)
            self.session = lean
            let outcome = try await lean.respond(to: userInput, generating: TurnOutcome.self, options: GenerationOptions(temperature: 0.3)).content
            let reply = Self.reply(from: outcome)
            recordLearned(phrase: userInput, reply: reply)
            return reply
        }
    }

    /// Maps a `TurnOutcome` to a reply string, encoding a clarifying question with the
    /// `ASK:` sentinel the pipeline detects (`presentJarvisReply`).
    private static func reply(from outcome: TurnOutcome) -> String {
        if let question = outcome.clarifyingQuestion, !question.isEmpty {
            return kClarificationPrefix + " " + question
        }
        return outcome.reply ?? ""
    }

    /// Fire-and-forget: teach `CommandLearner` which tool this phrase used (inferred from the
    /// reply) so repeated commands get pre-selected and eventually promoted.
    private func recordLearned(phrase: String, reply: String) {
        let toolHint = CommandLearner.inferTool(from: reply)
        Task { await CommandLearner.shared.record(phrase: phrase, toolName: toolHint) }
    }

    /// BigJob lane: the user asked for a bulk background job, so the turn MUST end with the
    /// job started exactly once. We ask the model to call `start_long_task` (retrying once
    /// with a firmer prompt if it replies in prose instead); if it still won't, we start the
    /// job directly. `StartLongTaskTool.wasCalled` is the single source of truth for "already
    /// started" and is checked only after each `respond()` fully returns (so any tool call
    /// has completed) — which means the direct fallback fires at most once and can never
    /// double-launch the job.
    private func runBigJobTurn(userInput: String, instructions: String) async -> String {
        await MainActor.run { StartLongTaskTool.wasCalled = false }
        let opts = GenerationOptions(temperature: 0.2, maximumResponseTokens: 512)
        let prompts = [
            instructions + "\n\nThis is a large repetitive job. Call start_long_task with the full goal in plain language.",
            instructions + "\n\nCRITICAL: You MUST call the start_long_task tool. Do not reply in prose without calling it.",
        ]

        for (attempt, prompt) in prompts.enumerated() {
            let session = LanguageModelSession(tools: [StartLongTaskTool()], instructions: prompt)
            self.session = session
            var reply = ""
            do {
                let outcome: TurnOutcome = try await withTimeout(seconds: 40, errorDomain: "JarvisTurn", errorDescription: "bigJob turn timed out after 40s") {
                    try await session.respond(to: userInput, generating: TurnOutcome.self, options: opts).content
                }
                reply = Self.reply(from: outcome)
            } catch {
                print("[COORDINATOR] bigJob attempt \(attempt + 1) failed (\(error.localizedDescription)).")
            }
            // respond() has fully returned, so any tool call has finished and wasCalled is
            // stable. If the job started, we're done — never retry or start it again.
            if await MainActor.run(body: { StartLongTaskTool.wasCalled }) {
                let finalReply = reply.isEmpty ? Self.backgroundJobReply : reply
                recordLearned(phrase: userInput, reply: finalReply)
                return finalReply
            }
        }

        // The model never called the tool across both attempts — start the job directly,
        // exactly once (wasCalled is false here, so the tool did not run).
        print("[COORDINATOR] bigJob: model never called start_long_task; starting directly.")
        let directReply = LongTaskEngine.start(goal: userInput)
        recordLearned(phrase: userInput, reply: directReply)
        return directReply
    }
}

// MARK: - OSControlAgent

/// A warm, reused session for OS-control escalations. Previously each call built a brand
/// new `LanguageModelSession`, which re-processes the instructions + tool schemas from
/// scratch every time — real latency and allocation cost on an 8 GB Mac for what should be
/// a cheap delegation hop. Caching the session (recreated only every 12 turns, matching
/// `SottoIntelligence`'s polish-session bound) removes that repeated cold-start cost while
/// still bounding transcript growth.
public actor OSControlAgent: SubAgent {
    public static let shared = OSControlAgent()
    private init() {}

    private var session: LanguageModelSession?
    private var turnCount = 0
    public var isWarm: Bool { session != nil }

    private static let instructions = "You are the OS Control Agent. Execute the requested system task using the available tools, then report what actually happened in one line."

    private func getOrCreateSession(for task: String) async -> LanguageModelSession {
        // Reuse the real catalog's keyword routing so this agent always has working,
        // relevant tools (a hardcoded name list would drift out of sync with JarvisToolbox).
        if let session, turnCount < 12 {
            turnCount += 1
            return session
        }
        let tools = await JarvisToolbox.routed(for: task)
        let fresh = LanguageModelSession(tools: tools, instructions: Self.instructions)
        session = fresh
        turnCount = 1
        return fresh
    }

    public func run(task: String) async -> String {
        let session = await getOrCreateSession(for: task)
        do {
            let response = try await session.respond(to: task, options: GenerationOptions(temperature: 0.2))
            return response.content
        } catch {
            return "OS Control Agent failed: \(error.localizedDescription)"
        }
    }

    /// Free the resident session (e.g. on memory pressure on 8 GB Macs).
    public func unload() {
        if session != nil {
            Task { @MainActor in MemoryLedger.shared.recordEviction() }
        }
        session = nil
        turnCount = 0
    }
}

// MARK: - WebResearcherAgent

/// Same session-reuse rationale as `OSControlAgent` — the tool set here is fixed, so there's
/// no need to rebuild the session on every escalation.
public actor WebResearcherAgent: SubAgent {
    public static let shared = WebResearcherAgent()
    private init() {}

    private var session: LanguageModelSession?
    private var turnCount = 0
    public var isWarm: Bool { session != nil }

    private static let instructions = """
        You are the Web Researcher Agent. Perform web search, screen parsing, and clicking using the provided tools.
        1. Read the screen using read_screen to get elements or element IDs.
        2. Click or set values using those labels or integer IDs.
        3. Search Wikipedia for external information.
        4. Report your final answer directly when done or when you cannot proceed further.
        """

    private func getOrCreateSession() -> LanguageModelSession {
        if let session, turnCount < 12 {
            turnCount += 1
            return session
        }
        let tools: [any Tool] = [
            WikipediaLookupTool(),
            ReadScreenTool(),
            ClickElementTool(),
            SetScreenElementValueTool()
        ]
        let fresh = LanguageModelSession(tools: tools, instructions: Self.instructions)
        session = fresh
        turnCount = 1
        return fresh
    }

    public func run(task: String) async -> String {
        let session = getOrCreateSession()
        do {
            let response = try await session.respond(to: task, options: GenerationOptions(temperature: 0.2))
            return response.content
        } catch {
            return "Web research failed: \(error.localizedDescription)"
        }
    }

    /// Free the resident session (e.g. on memory pressure on 8 GB Macs).
    public func unload() {
        if session != nil {
            Task { @MainActor in MemoryLedger.shared.recordEviction() }
        }
        session = nil
        turnCount = 0
    }
}

// MARK: - ScriptingExecutorAgent

/// Same session-reuse rationale as `OSControlAgent`/`WebResearcherAgent`. The system prompt
/// is fixed (script-generation instructions never change per task), so there's no reason to
/// re-process it into a fresh session on every escalation.
public actor ScriptingExecutorAgent: SubAgent {
    public static let shared = ScriptingExecutorAgent()
    private init() {}

    private var session: LanguageModelSession?
    private var turnCount = 0
    public var isWarm: Bool { session != nil }

    private static let systemPrompt = """
        You are a Swift Script Generator. Generate a valid, compiling Swift script that performs the requested task and prints the result to standard output.
        Do NOT include any explanations, markdown block formatting, or code fences (do NOT wrap code in ```swift). Output ONLY raw Swift code.
        Example to get total disk space:
        import Foundation
        let fileManager = FileManager.default
        if let attrs = try? fileManager.attributesOfFileSystem(forPath: "/"),
           let space = attrs[.systemSize] as? Int64 {
            print("Total disk space: \\(space) bytes")
        }
        """

    private func getOrCreateSession() -> LanguageModelSession {
        if let session, turnCount < 12 {
            turnCount += 1
            return session
        }
        let fresh = LanguageModelSession(instructions: Self.systemPrompt)
        session = fresh
        turnCount = 1
        return fresh
    }

    public func run(task: String) async -> String {
        let response: String
        if CoordinatorAgent.isMockMode {
            response = """
            import Foundation
            let fileManager = FileManager.default
            if let attrs = try? fileManager.attributesOfFileSystem(forPath: "/"),
               let space = attrs[.systemSize] as? Int64 {
                print("Total disk space: \\(space) bytes")
            }
            """
        } else {
            do {
                let session = getOrCreateSession()
                let res = try await session.respond(to: task, generating: SwiftScript.self, options: GenerationOptions(temperature: 0.1))
                response = res.content.code
            } catch {
                return "Scripting Executor Agent generation failed: \(error.localizedDescription)"
            }
        }
        
        print("[SCRIPTING_EXECUTOR] Generated script:\n\(response)")
        
        // Clean up markdown block formatting if present
        var cleanedScript = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedScript.hasPrefix("```swift") {
            cleanedScript = String(cleanedScript.dropFirst("```swift".count))
            if cleanedScript.hasSuffix("```") {
                cleanedScript = String(cleanedScript.dropLast("```".count))
            }
        } else if cleanedScript.hasPrefix("```") {
            cleanedScript = String(cleanedScript.dropFirst("```".count))
            if cleanedScript.hasSuffix("```") {
                cleanedScript = String(cleanedScript.dropLast("```".count))
            }
        }
        cleanedScript = cleanedScript.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // SECURITY: Never auto-execute LLM-generated code. Draft it as a DISABLED skill
        // so the user must explicitly say "enable skill <name>" before it runs.
        // This preserves the SkillStore approval gate for all agent-generated scripts.
        // Stable name derived from task content (hashValue is non-deterministic per process run)
        let stableKey = task.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.prefix(6)
            .joined(separator: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let skillName = "skill_\(stableKey.isEmpty ? "task" : stableKey)"
        let draftResult = SkillStore.draft(
            name: skillName,
            description: "Generated for: \(task.prefix(80))",
            trigger: task,
            language: "swift",
            body: cleanedScript
        )
        return "I drafted a Swift script for '\(task.prefix(60))'. " +
               "Say 'enable skill \(skillName)' to approve and run it, or ask to show its code first.\n\(draftResult)"
    }

    /// Free the resident session (e.g. on memory pressure on 8 GB Macs).
    public func unload() {
        if session != nil {
            Task { @MainActor in MemoryLedger.shared.recordEviction() }
        }
        session = nil
        turnCount = 0
    }
}
