#if DEBUG
import Foundation
import AppKit

public func runFallbackIntegrationTest() async -> Bool {
    print("[TEST] Running fallback integration test for macOS < 26.0...")
    var currentInput = "read the screen, write a swift script to compute total disk space, and tell me the result"
    var turnOutput = ""
    
    // Simulate Coordinator loop of at least two turns
    for turn in 1...2 {
        print("[TEST] Coordinator Turn \(turn) starting with: \(currentInput)")
        if turn == 1 {
            // Turn 1: AX Screen Parser
            let screenMarkup = ScreenParser.captureActiveWindowTree()
            print("[TEST] AX Screen Parser output (\(screenMarkup.count) characters):")
            
            // Log a sample of the screen tree to verify structured bounds
            let lines = screenMarkup.split(separator: "\n")
            for line in lines.prefix(5) {
                print("  \(line)")
            }
            if lines.count > 5 {
                print("  ... (\(lines.count - 5) more lines)")
            }
            
            if screenMarkup.isEmpty {
                print("❌ AX Screen Parser returned empty string.")
                return false
            }
            print("✅ AX Screen Parser executed successfully.")
            
            currentInput = "Screen parsed successfully. Now run script."
        } else if turn == 2 {
            // Turn 2: Scripting Executor
            let scriptCode = """
            import Foundation
            let fileManager = FileManager.default
            if let attrs = try? fileManager.attributesOfFileSystem(forPath: "/"),
               let space = attrs[.systemSize] as? Int64 {
                print("Total disk space: \\(space) bytes")
            }
            """
            print("[TEST] Scripting Executor running SwiftScriptRunner with script code...")
            let result = await SwiftScriptRunner.run(scriptCode: scriptCode)
            print("[TEST] SwiftScriptRunner result success: \(result.success), exitCode: \(result.exitCode)")
            print("[TEST] SwiftScriptRunner stdout: \(result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
            print("[TEST] SwiftScriptRunner stderr: \(result.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
            
            if !result.success {
                print("❌ SwiftScriptRunner failed to run: \(result.stderr)")
                return false
            }
            
            if !result.stdout.contains("Total disk space:") {
                print("❌ SwiftScriptRunner output does not contain expected total disk space message: \(result.stdout)")
                return false
            }
            
            turnOutput = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            print("✅ Scripting Executor executed successfully.")
        }
    }
    
    print("[TEST] Ingesting back script output: \(turnOutput)")
    print("✅ Fallback integration test: PASSED")
    return true
}

@available(macOS 26.0, *)
public func runCoordinatorAgentIntegrationTest() async -> Bool {
    print("[TEST] Running CoordinatorAgent integration test for macOS 26.0+...")
    CoordinatorAgent.isMockMode = true
    let agent = CoordinatorAgent()
    do {
        let result = try await agent.handleTurn(userInput: "read the screen, write a swift script to compute total disk space, and tell me the result")
        print("[TEST] CoordinatorAgent result:\n\(result)")
        if result.contains("drafted a Swift script") {
            print("✅ CoordinatorAgent integration test: PASSED")
            return true
        } else {
            print("❌ CoordinatorAgent integration test: FAILED (Output did not contain expected content)")
            return false
        }
    } catch {
        print("❌ CoordinatorAgent integration test: FAILED with error: \(error)")
        return false
    }
}

/// Drift guard: every tool exposed to the model (`JarvisToolbox.all()`) must have a
/// matching `CapabilityDescriptor` in the registry, and every reflex the kernel binds
/// must name a real registered capability. This is the safety the future `@Skill` macro
/// would enforce at compile time — until then, it fails the test suite the moment a new
/// tool is added without its registry entry, so the two never silently drift apart.
@available(macOS 26.0, *)
public func runCapabilityConsistencyCheck() async -> Bool {
    print("[TEST] Running capability/registry consistency check...")
    await CapabilityRegistry.shared.seedBuiltins()
    await Kernel.shared.seedReflexes()

    let registered = Set(await CapabilityRegistry.shared.allNames())
    let toolNames = JarvisToolbox.all().map { $0.name }

    var ok = true
    let missing = toolNames.filter { !registered.contains($0) }
    if missing.isEmpty {
        print("✅ All \(toolNames.count) tools have a registered capability descriptor.")
    } else {
        print("❌ Tools missing a CapabilityDescriptor (add them to CapabilityRegistry.seedBuiltins): \(missing.joined(separator: ", "))")
        ok = false
    }

    // Every reflex the kernel binds must resolve to a registered reflex-tier capability.
    let reflexNames = await Kernel.shared.boundReflexNames()
    let badReflexes = reflexNames.filter { !registered.contains($0) }
    if badReflexes.isEmpty {
        print("✅ All \(reflexNames.count) kernel reflexes map to a registered capability.")
    } else {
        print("❌ Kernel reflexes with no registered capability: \(badReflexes.joined(separator: ", "))")
        ok = false
    }
    return ok
}

public func runDynamicSkillTriggerTest() -> Bool {
    print("[TEST] Running dynamic skill trigger check...")
    CommandEngine.registerSkillTrigger("clean my desktop", skillName: "clean_desktop")
    
    guard let match = CommandEngine.checkZeroLatencyShortcut(for: "clean my desktop") else {
        print("❌ Dynamic skill trigger failed to match exact phrase.")
        return false
    }
    if match.command != "skill:clean_desktop" {
        print("❌ Dynamic skill trigger match has wrong command: \(match.command)")
        return false
    }
    
    guard let matchPunct = CommandEngine.checkZeroLatencyShortcut(for: "clean my desktop.") else {
        print("❌ Dynamic skill trigger failed to match phrase with trailing punctuation.")
        return false
    }
    if matchPunct.command != "skill:clean_desktop" {
        print("❌ Dynamic skill trigger match with punctuation has wrong command: \(matchPunct.command)")
        return false
    }
    
    if let mismatch = CommandEngine.checkZeroLatencyShortcut(for: "clean my desk") {
        print("❌ Dynamic skill trigger matched incorrect phrase: \(mismatch.command)")
        return false
    }
    
    print("✅ Dynamic skill trigger check: PASSED")
    return true
}

public func runSottoIntegrationTests() async -> Bool {
    print("=== STARTING SOTTO INTEGRATION TESTS ===")
    var success: Bool
    if #available(macOS 26.0, *) {
        success = await runCoordinatorAgentIntegrationTest()
        if success { success = await runCapabilityConsistencyCheck() }
        if success { success = runDynamicSkillTriggerTest() }
        if success {
            print("[TEST] Verifying JarvisEvaluation runner (forceMock)...")
            success = await JarvisEvaluation.run(forceMock: true)
        }
    } else {
        success = await runFallbackIntegrationTest()
    }
    if success {
        print("=== ALL INTEGRATION TESTS PASSED ===")
    } else {
        print("=== INTEGRATION TESTS FAILED ===")
    }
    return success
}
#endif
