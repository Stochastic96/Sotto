import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Delegation Tools

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct DelegateOSControlTool: Tool {
    let name = "delegate_to_os_control"
    let description = "Delegate native macOS control tasks (volume, brightness, power, notes, reminders, calendar) to the OS Control Agent."

    @Generable
    struct Arguments {
        @Guide(description: "The specific OS task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await OSControlAgent.run(task: arguments.task)
    }
}

@available(macOS 26.0, *)
struct DelegateWebResearcherTool: Tool {
    let name = "delegate_to_web_researcher"
    let description = "Delegate web search, screen reading, and clicking actions to the Web Researcher Agent."

    @Generable
    struct Arguments {
        @Guide(description: "The web research task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await WebResearcherAgent.run(task: arguments.task)
    }
}

@available(macOS 26.0, *)
struct DelegateScriptingExecutorTool: Tool {
    let name = "delegate_to_scripting_executor"
    let description = "Delegate complex computational or automation tasks requiring writing and running Swift scripts to the Scripting Executor Agent."

    @Generable
    struct Arguments {
        @Guide(description: "The scripting task to perform.")
        let task: String
    }

    func call(arguments: Arguments) async throws -> String {
        return await ScriptingExecutorAgent.run(task: arguments.task)
    }
}

@available(macOS 26.0, *)
struct ReadScreenTreeTool: Tool {
    let name = "read_screen_tree"
    let description = "Read the interactive UI element tree of the active window. Returns element descriptions and their integer IDs. Call this before clicking or setting values."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let tree = ScreenParser.captureActiveWindowTree()
        if tree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Screen capture unavailable. Ensure Screen Recording permission is granted and a window is active."
        }
        return tree
    }
}

@available(macOS 26.0, *)
struct ClickScreenElementTool: Tool {
    let name = "click_screen_element"
    let description = "Click an interactive UI element by its integer ID obtained from read_screen_tree."

    @Generable
    struct Arguments {
        @Guide(description: "The integer ID of the element to click.")
        let id: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let success = ScreenParser.performClick(id: arguments.id)
        return success ? "Successfully clicked element with ID \(arguments.id)." : "Failed to click element with ID \(arguments.id). Element not found or action failed."
    }
}

@available(macOS 26.0, *)
struct SetScreenElementValueTool: Tool {
    let name = "set_screen_element_value"
    let description = "Set a text value on an input element by its integer ID obtained from read_screen_tree."

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
#endif

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
@available(macOS 26.0, *)
public actor CoordinatorAgent {
    public static var isMockMode = false

    #if canImport(FoundationModels)
    // Retained across a clarification round-trip so the follow-up answer lands in the same
    // multi-turn transcript. Actor isolation replaces the need for explicit locking.
    private var session: LanguageModelSession?
    #endif

    public init() {}

    /// Warm a session at launch so the first Jarvis command has no cold-start penalty.
    /// Mirrors JarvisAgent.prewarm() — one prewarm per session-type is sufficient.
    public static func prewarm() {
        #if canImport(FoundationModels)
        Task {
            guard SystemLanguageModel.default.isAvailable else { return }
            LanguageModelSession().prewarm()
            try? await Task.sleep(for: .seconds(30))
            guard SystemLanguageModel.default.isAvailable else { return }
            LanguageModelSession().prewarm()
            print("[COORDINATOR] Prewarmed Apple Intelligence session.")
        }
        #endif
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
                    let scriptResult = await ScriptingExecutorAgent.run(task: "compute total disk space")
                    print("[MOCK-COORDINATOR] Scripting Executor response: \(scriptResult)")
                    turnOutput = scriptResult
                }
            }

            // Turn 3: final ingestion
            print("[MOCK-COORDINATOR] Final Turn: ingesting back script result: \(turnOutput)")
            return "Final Result: The Swift script ran successfully. \(turnOutput)"
        }

        #if canImport(FoundationModels)
        // Follow-up answer to a clarifying question: continue the SAME session.
        if isFollowUp, let session = self.session {
            let response = try await session.respond(to: userInput, options: GenerationOptions(temperature: 0.3))
            return response.content
        }

        let conversation = await ConversationMemory.shared.digest()
        let instructions = buildInstructions(for: userInput, conversation: conversation)
        let routed = Array(JarvisToolbox.routed(for: userInput).prefix(5))

        // macOS 27+: drive the session with a native DynamicProfile.
        // Gated by SOTTO_FM27 (requires Swift 6.4+). Wrapped in a 30-second timeout
        // because the DynamicProfile tool-calling loop has no built-in cycle limit —
        // without maximumResponseTokens AND a timeout, a model with no city for
        // get_weather can loop asking for clarification indefinitely.
        #if SOTTO_FM27
        if #available(macOS 27.0, *) {
            let mode = JarvisProfile.classify(userInput)
            print("[COORDINATOR] DynamicProfile lane: \(mode.rawValue)  (routed: \(routed.map { $0.name }.joined(separator: ", ")))")
            do {
                let session = LanguageModelSession(profile: JarvisProfile(mode: mode, instructions: instructions, routedTools: routed))
                self.session = session
                // 30-second hard timeout: if DynamicProfile doesn't return, fall through
                // to the stable macOS 26 hand-built path rather than hanging forever.
                let opts = GenerationOptions(temperature: 0.3, maximumResponseTokens: 512)
                let reply: String = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await session.respond(to: userInput, options: opts).content
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(40))
                        throw NSError(domain: "JarvisDP", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "DynamicProfile timed out after 40s"])
                    }
                    guard let result = try await group.next() else {
                        throw NSError(domain: "JarvisDP", code: -2,
                                      userInfo: [NSLocalizedDescriptionKey: "No result from DynamicProfile"])
                    }
                    group.cancelAll()
                    return result
                }
                return reply
            } catch {
                print("[COORDINATOR] DynamicProfile failed (\(error.localizedDescription)); falling back to macOS 26 path.")
                // Log feedback for DynamicProfile failures so Apple can improve model stability
                JarvisDiagnostics.record(
                    session: self.session,
                    error: error,
                    input: userInput,
                    description: "DynamicProfile session failed or timed out",
                    category: .toolCallLoop
                )
            }
        }
        #endif

        // Default path (macOS 26, or 27 without the 6.4 toolchain): build the session by hand
        // with the routed tools + the escalation handoffs. Capped at ≤12 tools so the prompt +
        // tool schemas stay inside the model's larger context window. (start_long_task is reachable
        // via its own routed keyword group, so it isn't always-on here.)
        var tools: [any Tool] = routed
        let escalation: [any Tool] = [
            DelegateScriptingExecutorTool(),
            DelegateWebResearcherTool(),
            DelegateOSControlTool(),
        ]
        for tool in escalation where !tools.contains(where: { $0.name == tool.name }) {
            tools.append(tool)
        }
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        self.session = session
        print("[COORDINATOR] Tools: \(tools.map { $0.name }.joined(separator: ", "))")
        do {
            let response = try await session.respond(to: userInput, options: GenerationOptions(temperature: 0.3))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            // The model's context window was exceeded — usually a very long writing
            // request plus the tool schemas. Retry once with a minimal, tool-free session so
            // the request still gets answered (Apple's guidance: shed context and re-respond).
            if case .exceededContextWindowSize = error {
                print("[COORDINATOR] Context window exceeded — retrying tool-free.")
                let lean = LanguageModelSession(instructions: JarvisAgent.instructions)
                self.session = lean
                return try await lean.respond(to: userInput, options: GenerationOptions(temperature: 0.3)).content
            }
            throw error
        }
        #else
        throw NSError(domain: "CoordinatorAgent", code: -1, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is unavailable."])
        #endif
    }
}

// MARK: - OSControlAgent

@available(macOS 26.0, *)
public class OSControlAgent {
    public static func run(task: String) async -> String {
        #if canImport(FoundationModels)
        // Reuse the real catalog's keyword routing so this agent always has working,
        // relevant tools (the previous hardcoded name list held phantom names).
        let tools = JarvisToolbox.routed(for: task)
        let instructions = "You are the OS Control Agent. Execute the requested system task using the available tools, then report what actually happened in one line."
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        do {
            let response = try await session.respond(to: task, options: GenerationOptions(temperature: 0.2))
            return response.content
        } catch {
            return "OS Control Agent failed: \(error.localizedDescription)"
        }
        #else
        return "OS Control Agent unavailable: Apple Intelligence not supported."
        #endif
    }
}

// MARK: - WebResearcherAgent

@available(macOS 26.0, *)
public class WebResearcherAgent {
    public static func run(task: String) async -> String {
        #if canImport(FoundationModels)
        let tools: [any Tool] = [
            WikipediaLookupTool(),
            ReadScreenTreeTool(),
            ClickScreenElementTool(),
            SetScreenElementValueTool()
        ]
        let instructions = """
            You are the Web Researcher Agent. Perform web search, screen parsing, and clicking using the provided tools.
            1. Read the screen using read_screen_tree to get element IDs.
            2. Click or set values using those integer IDs.
            3. Search Wikipedia for external information.
            4. Report your final answer directly when done or when you cannot proceed further.
            """
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        do {
            let response = try await session.respond(to: task, options: GenerationOptions(temperature: 0.2))
            return response.content
        } catch {
            return "Web research failed: \(error.localizedDescription)"
        }
        #else
        return "Web Researcher Agent requires Foundation Models (macOS 26+)."
        #endif
    }
}

// MARK: - ScriptingExecutorAgent

@available(macOS 26.0, *)
public class ScriptingExecutorAgent {
    public static func run(task: String) async -> String {
        let systemPrompt = """
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
                #if canImport(FoundationModels)
                let session = LanguageModelSession(instructions: systemPrompt)
                let res = try await session.respond(to: task, options: GenerationOptions(temperature: 0.1))
                response = res.content
                #else
                return "Scripting Executor Agent requires Foundation Models (macOS 26+)."
                #endif
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
        let skillName = "script_\(abs(task.hashValue) % 99999)"
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
}
