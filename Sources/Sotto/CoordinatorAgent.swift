import Foundation
import FoundationModels

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

    @Generable
    struct Arguments {
        @Guide(description: "The specific OS task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await OSControlAgent.shared.run(task: arguments.task)
    }
}

struct DelegateWebResearcherTool: Tool {
    let name = "delegate_to_web_researcher"
    let description = "Delegate web search, screen reading, and clicking actions to the Web Researcher Agent."

    @Generable
    struct Arguments {
        @Guide(description: "The web research task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await WebResearcherAgent.shared.run(task: arguments.task)
    }
}

struct DelegateScriptingExecutorTool: Tool {
    let name = "delegate_to_scripting_executor"
    let description = "Delegate complex computational or automation tasks requiring writing and running Swift scripts to the Scripting Executor Agent."

    @Generable
    struct Arguments {
        @Guide(description: "The scripting task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await ScriptingExecutorAgent.shared.run(task: arguments.task)
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
/// loop itself) plus escalation tools that hand off to the MLX sub-agents only when a task
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
            let outcome = response.content
            if let question = outcome.clarifyingQuestion, !question.isEmpty {
                return kClarificationPrefix + " " + question
            }
            return outcome.reply ?? ""
        }

        let conversation = await ConversationMemory.shared.digest()
        let instructions = buildInstructions(for: userInput, conversation: conversation)
        let routed = Array(await JarvisToolbox.routed(for: userInput).prefix(5))

        // Drive the session manually by constructing LanguageModelSession with custom instructions and tools
        // matching the active lane. Bypasses LanguageModelSession(profile:) to prevent dyld Symbol not found crashes.
        let mode = JarvisProfile.classify(userInput)
        print("[COORDINATOR] Lane: \(mode.rawValue)  (routed: \(routed.map { $0.name }.joined(separator: ", ")))")
        
        let temperature: Double
        switch mode {
        case .chat:
            temperature = 0.7
        case .bigJob:
            temperature = 0.2
        case .quick:
            temperature = 0.3
        }
        
        if mode == .bigJob {
            await MainActor.run { StartLongTaskTool.wasCalled = false }
        }
        
        let escalationTools: [any Tool] = [DelegateScriptingExecutorTool(), DelegateWebResearcherTool(), DelegateOSControlTool(), StartLongTaskTool()]
        let session: LanguageModelSession
        switch mode {
        case .chat:
            // Chat lane: warm, brief, no tools.
            session = LanguageModelSession(instructions: instructions + "\n\nThis is small talk — reply warmly in ONE short line and use no tools.")
        case .bigJob:
            // BigJob lane: narrow to the long task tool and require it in instructions.
            session = LanguageModelSession(tools: [StartLongTaskTool()], instructions: instructions + "\n\nThis is a large repetitive job. Call start_long_task with the full goal in plain language.")
        case .quick:
            // Quick lane: native routed tools + escalation tools.
            session = LanguageModelSession(tools: routed + escalationTools, instructions: instructions)
        }
        self.session = session

        do {
            // 40-second hard timeout: the DynamicProfile tool-calling loop has no built-in
            // cycle limit — without maximumResponseTokens AND a timeout, a model with no
            // city for get_weather can loop asking for clarification indefinitely.
            let opts = GenerationOptions(temperature: temperature, maximumResponseTokens: 512)
            let outcome: TurnOutcome = try await withTimeout(seconds: 40, errorDomain: "JarvisDP", errorDescription: "DynamicProfile timed out after 40s") {
                let res = try await session.respond(to: userInput, generating: TurnOutcome.self, options: opts)
                return res.content
            }
            
            let wasCalled = await MainActor.run { StartLongTaskTool.wasCalled }
            if mode == .bigJob && !wasCalled {
                print("[COORDINATOR] bigJob turn completed but start_long_task was not called. Retrying once with a stronger prompt...")
                let retryInstructions = instructions + "\n\nCRITICAL: You MUST call the start_long_task tool. Do not reply in prose without calling it."
                let retrySession = LanguageModelSession(tools: [StartLongTaskTool()], instructions: retryInstructions)
                do {
                    let retryOutcome: TurnOutcome = try await withTimeout(seconds: 40, errorDomain: "JarvisDP", errorDescription: "DynamicProfile retry timed out after 40s") {
                        let res = try await retrySession.respond(to: userInput, generating: TurnOutcome.self, options: opts)
                        return res.content
                    }
                    
                    let retryWasCalled = await MainActor.run { StartLongTaskTool.wasCalled }
                    if retryWasCalled {
                        let reply = retryOutcome.reply ?? ""
                        let toolHint = CommandLearner.inferTool(from: reply)
                        Task { await CommandLearner.shared.record(phrase: userInput, toolName: toolHint) }
                        return reply
                    }
                } catch {
                    print("[COORDINATOR] Retry failed (\(error.localizedDescription)). Routing directly.")
                }
                
                let finalWasCalled = await MainActor.run { StartLongTaskTool.wasCalled }
                if finalWasCalled {
                    print("[COORDINATOR] Retry failed/timed out, but tool was already executed. Returning background starting reply.")
                    let reply = Self.backgroundJobReply
                    let toolHint = CommandLearner.inferTool(from: reply)
                    Task { await CommandLearner.shared.record(phrase: userInput, toolName: toolHint) }
                    return reply
                } else {
                    print("[COORDINATOR] Retry did not call start_long_task. Routing to LongTaskEngine directly.")
                    let directReply = LongTaskEngine.start(goal: userInput)
                    let toolHint = CommandLearner.inferTool(from: directReply)
                    Task { await CommandLearner.shared.record(phrase: userInput, toolName: toolHint) }
                    return directReply
                }
            }
            
            let reply: String
            if let question = outcome.clarifyingQuestion, !question.isEmpty {
                reply = kClarificationPrefix + " " + question
            } else {
                reply = outcome.reply ?? ""
            }
            let toolHint = CommandLearner.inferTool(from: reply)
            Task { await CommandLearner.shared.record(phrase: userInput, toolName: toolHint) }
            return reply
        } catch {
            if mode == .bigJob {
                let wasCalled = await MainActor.run { StartLongTaskTool.wasCalled }
                if wasCalled {
                    print("[COORDINATOR] bigJob failed/timed out, but start_long_task was already executed. Returning background starting reply.")
                    let reply = Self.backgroundJobReply
                    let toolHint = CommandLearner.inferTool(from: reply)
                    Task { await CommandLearner.shared.record(phrase: userInput, toolName: toolHint) }
                    return reply
                } else {
                    print("[COORDINATOR] bigJob failed in DynamicProfile. Routing directly to LongTaskEngine.")
                    let directReply = LongTaskEngine.start(goal: userInput)
                    let toolHint = CommandLearner.inferTool(from: directReply)
                    Task { await CommandLearner.shared.record(phrase: userInput, toolName: toolHint) }
                    return directReply
                }
            }
            print("[COORDINATOR] DynamicProfile failed (\(error.localizedDescription)); retrying tool-free.")
            self.session = nil
            await Task.yield()
            // Log feedback for DynamicProfile failures so Apple can improve model stability.
            JarvisDiagnostics.record(
                session: self.session,
                error: error,
                input: userInput,
                description: "DynamicProfile session failed or timed out",
                category: .toolCallLoop
            )
            // Retry once with a minimal, tool-free session — sheds context and re-responds
            // (Apple's own guidance for a context-window overrun) so a transient
            // DynamicProfile hiccup or timeout doesn't leave Jarvis silent for the turn.
            let lean = LanguageModelSession(instructions: JarvisAgent.instructions)
            self.session = lean
            let response = try await lean.respond(to: userInput, generating: TurnOutcome.self, options: GenerationOptions(temperature: 0.3))
            let outcome = response.content
            let reply: String
            if let question = outcome.clarifyingQuestion, !question.isEmpty {
                reply = kClarificationPrefix + " " + question
            } else {
                reply = outcome.reply ?? ""
            }
            let toolHint = CommandLearner.inferTool(from: reply)
            Task { await CommandLearner.shared.record(phrase: userInput, toolName: toolHint) }
            return reply
        }
    }
}

// MARK: - OSControlAgent

/// A warm, reused session for OS-control escalations. Previously each call built a brand
/// new `LanguageModelSession`, which re-processes the instructions + tool schemas from
/// scratch every time — real latency and allocation cost on an 8 GB Mac for what should be
/// a cheap delegation hop. Caching the session (recreated only every 12 turns, matching
/// `SottoIntelligence`'s polish-session bound) removes that repeated cold-start cost while
/// still bounding transcript growth.
public actor OSControlAgent {
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
public actor WebResearcherAgent {
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
public actor ScriptingExecutorAgent {
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
