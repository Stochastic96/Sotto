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
@available(macOS 26.0, *)
public class CoordinatorAgent {
    public static var isMockMode = false

    #if canImport(FoundationModels)
    // Retained across a clarification round-trip so the follow-up answer lands in the same
    // multi-turn transcript.
    private var session: LanguageModelSession?
    #endif

    public init() {}

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
        let routed = Array(JarvisToolbox.routed(for: userInput).prefix(8))

        // macOS 27+ (with the Swift 6.4 toolchain): drive the session with a native
        // DynamicProfile so the lane controls the tools, temperature, and tool-calling mode
        // (chat forbids tools; big-job requires start_long_task). Gated by SOTTO_FM27 — see
        // JarvisProfile.swift for why.
        #if SOTTO_FM27
        if #available(macOS 27.0, *) {
            let mode = JarvisProfile.classify(userInput)
            print("[COORDINATOR] DynamicProfile lane: \(mode.rawValue)  (routed: \(routed.map { $0.name }.joined(separator: ", ")))")
            let session = LanguageModelSession(profile: JarvisProfile(mode: mode, instructions: instructions, routedTools: routed))
            self.session = session
            return try await session.respond(to: userInput).content
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
        if !SettingsController.preferMLX {
            print("[WEB_RESEARCHER] Running native tool-calling WebResearcherAgent via Apple Intelligence...")
            let tools: [any Tool] = [
                WikipediaLookupTool(),
                ReadScreenTreeTool(),
                ClickScreenElementTool(),
                SetScreenElementValueTool()
            ]
            let instructions = """
                You are the Web Researcher Agent. Your task is to perform web search, screen parsing, and clicking using the provided tools.
                1. Read the screen first using read_screen_tree to get elements and their integer IDs.
                2. Click or set values on elements using their integer IDs.
                3. Search Wikipedia or the web if you need external information.
                4. When you have successfully completed the task or cannot proceed further, report your final answer directly.
                """
            let session = LanguageModelSession(tools: tools, instructions: instructions)
            do {
                let response = try await session.respond(to: task, options: GenerationOptions(temperature: 0.2))
                print("[WEB_RESEARCHER] Native agent succeeded with response: \(response.content)")
                return response.content
            } catch {
                print("[WEB_RESEARCHER] Native agent failed: \(error.localizedDescription). Falling back to MLX/manual loop...")
            }
        }
        #endif

        let systemPrompt = """
            You are the Web Researcher Agent. Your task is to perform web search, screen parsing, and clicking.
            You must choose ONE action per turn. Available actions:
            1. Action: search(query: "...") - Search Wikipedia/web for info. Returns a text summary.
            2. Action: read_screen - Read the UI tree of the active window. Returns numbered element IDs.
            3. Action: click(id: 42) - Click element by its INTEGER id from read_screen output. IDs are numbers only.
            4. Action: set_value(id: 42, value: "...") - Set text on element by INTEGER id.
            5. Action: finish(answer: "...") - Return the final answer to the user.

            RULES:
            - ONE action per turn. Stop after each Action line and wait for the Observation.
            - click() and set_value() require INTEGER ids from read_screen. Never pass text labels as ids.
            - If read_screen returns no content or a permission error, call finish() immediately with what you know.
            - If the same action produces the same (empty/failed) result twice in a row, call finish() with your best answer.

            Output format must be exactly:
            Thought: [reasoning]
            Action: [action_name]([arguments])
            """

        var conversationHistory = "Task: \(task)\n"
        var turnCount = 0
        let maxTurns = 6
        var lastActionLine = ""
        var repeatedActionCount = 0

        while turnCount < maxTurns {
            turnCount += 1
            let response: String
            do {
                if SettingsController.preferMLX, await MLXEngine.shared.prepareIfNeeded() {
                    // Cap tokens tightly so the model doesn't write a multi-action essay.
                    response = try await MLXEngine.shared.generate(systemPrompt: systemPrompt, userPrompt: conversationHistory, temperature: 0.2, maxTokens: 256)
                } else {
                    #if canImport(FoundationModels)
                    let session = LanguageModelSession(instructions: systemPrompt)
                    let res = try await session.respond(to: conversationHistory, options: GenerationOptions(temperature: 0.2))
                    response = res.content
                    #else
                    return "Web Researcher Agent failed: MLX and Apple Intelligence both unavailable."
                    #endif
                }
            } catch {
                return "Web Researcher Agent generation failed: \(error.localizedDescription)"
            }

            // Only take the FIRST Action: line — ignore any extras the model hallucinated.
            let firstLine = response.components(separatedBy: "\n")
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Action:") }) ?? ""
            let actionLine = firstLine
                .replacingOccurrences(of: "Action:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Truncate response to just Thought + first Action line before appending to history,
            // so the model doesn't see the hallucinated loop on the next turn.
            let cleanedResponse: String
            if let thoughtRange = response.range(of: "Thought:"),
               let actionIdx = response.range(of: "Action:") {
                let afterAction = response[actionIdx.lowerBound...]
                let firstActionEnd = afterAction.firstIndex(of: "\n") ?? afterAction.endIndex
                cleanedResponse = String(response[thoughtRange.lowerBound..<firstActionEnd])
            } else {
                cleanedResponse = response
            }
            print("[WEB_RESEARCHER] Turn \(turnCount) action: \(actionLine)")
            conversationHistory += cleanedResponse + "\n"

            // Bail out if the same action repeats — means the model is stuck.
            if actionLine == lastActionLine {
                repeatedActionCount += 1
                if repeatedActionCount >= 2 {
                    return "Could not complete the task — the agent got stuck repeating '\(actionLine)'. Try rephrasing."
                }
            } else {
                repeatedActionCount = 0
            }
            lastActionLine = actionLine

            if actionLine.hasPrefix("finish") {
                return parseArg(line: actionLine, prefix: "finish")
            } else if actionLine.hasPrefix("read_screen") {
                let screenMarkup = ScreenParser.captureActiveWindowTree()
                if screenMarkup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    conversationHistory += "Observation: Screen capture unavailable — Screen Recording permission not granted in System Settings, or no window is active. Call finish() with your best answer based on search results.\n"
                } else {
                    conversationHistory += "Observation: Screen content (element ids are integers):\n\(screenMarkup)\n"
                }
            } else if actionLine.hasPrefix("search") {
                let query = parseArg(line: actionLine, prefix: "search")
                #if canImport(FoundationModels)
                let searchTool = WikipediaLookupTool()
                let result = (try? await searchTool.call(arguments: WikipediaLookupTool.Arguments(query: query))) ?? "Search failed."
                #else
                let result = "Search unavailable."
                #endif
                conversationHistory += "Observation: Search result:\n\(result)\n"
            } else if actionLine.hasPrefix("click") {
                let idStr = parseArg(line: actionLine, prefix: "click")
                if let id = Int(idStr.trimmingCharacters(in: .whitespaces)) {
                    let ok = ScreenParser.performClick(id: id)
                    conversationHistory += "Observation: Click on element [\(id)] \(ok ? "succeeded" : "failed — element not found").\n"
                } else {
                    conversationHistory += "Observation: click() requires an INTEGER id from read_screen output (e.g. click(42)), not a text label. Read the screen first to get element ids.\n"
                }
            } else if actionLine.hasPrefix("set_value") {
                let argsStr = parseArg(line: actionLine, prefix: "set_value")
                let parts = argsStr.components(separatedBy: ",")
                if let first = parts.first, let id = Int(first.trimmingCharacters(in: .whitespaces)), parts.count > 1 {
                    let val = parts[1...].joined(separator: ",").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                    let ok = ScreenParser.performSetValue(id: id, value: val)
                    conversationHistory += "Observation: Setting value on [\(id)] \(ok ? "succeeded" : "failed").\n"
                } else {
                    conversationHistory += "Observation: set_value() requires an INTEGER id and a value, e.g. set_value(42, \"hello\").\n"
                }
            } else {
                conversationHistory += "Observation: Unrecognized action. Use: search, read_screen, click(INTEGER_ID), set_value, finish.\n"
            }
        }

        return "Web Researcher Agent reached max turns without finishing."
    }
    
    private static func parseArg(line: String, prefix: String) -> String {
        guard let start = line.range(of: prefix + "("),
              let end = line.range(of: ")", options: .backwards, range: start.upperBound..<line.endIndex) else {
            return ""
        }
        return String(line[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
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
                if SettingsController.preferMLX, await MLXEngine.shared.prepareIfNeeded() {
                    response = try await MLXEngine.shared.generate(systemPrompt: systemPrompt, userPrompt: task, temperature: 0.1, maxTokens: 1024)
                } else {
                    #if canImport(FoundationModels)
                    let session = LanguageModelSession(instructions: systemPrompt)
                    let res = try await session.respond(to: task, options: GenerationOptions(temperature: 0.1))
                    response = res.content
                    #else
                    return "Scripting Executor Agent failed: MLX and Apple Intelligence both unavailable."
                    #endif
                }
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
        
        // Run SwiftScriptRunner
        let result = await SwiftScriptRunner.run(scriptCode: cleanedScript)
        if result.success {
            return "Script executed successfully. Output:\n\(result.stdout)"
        } else {
            return "Script execution failed with exit code \(result.exitCode).\nStderr:\n\(result.stderr)\nStdout:\n\(result.stdout)"
        }
    }
}
