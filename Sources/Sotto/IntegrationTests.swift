#if DEBUG
import Foundation
import AppKit

public func runCoordinatorAgentIntegrationTest() async -> Bool {
    print("[TEST] Running CoordinatorAgent integration test...")
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

    // Bidirectional check: every foundationModel or cloud capability in the registry must have a matching tool in the toolbox.
    let foundationModelCaps = await CapabilityRegistry.shared.allCapabilities().filter { $0.tier >= .foundationModel }
    let missingTools = foundationModelCaps.map { $0.name }.filter { !toolNames.contains($0) }
    if missingTools.isEmpty {
        print("✅ All \(foundationModelCaps.count) foundationModel/cloud capabilities have a matching tool in JarvisToolbox.")
    } else {
        print("❌ Capabilities in registry missing a Tool in JarvisToolbox: \(missingTools.joined(separator: ", "))")
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

    // Forward check: every reflex-tier capability MUST have a kernel binding. Without one,
    // the intent routes to reflex tier, finds no executor, and silently escalates to the
    // model — the exact drift this pass fixed.
    let boundReflexSet = Set(reflexNames)
    let reflexTierCaps = await CapabilityRegistry.shared.allCapabilities()
        .filter { $0.tier == .reflex }.map { $0.name }
    let unboundReflexCaps = reflexTierCaps.filter { !boundReflexSet.contains($0) }
    if unboundReflexCaps.isEmpty {
        print("✅ All \(reflexTierCaps.count) reflex-tier capabilities have a kernel binding.")
    } else {
        print("❌ Reflex-tier capabilities with no kernel binding (bind in Kernel.seedReflexes or raise their tier): \(unboundReflexCaps.joined(separator: ", "))")
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

public func runBridgeAuditIntegrationTest() -> Bool {
    print("[TEST] Running BridgeAudit integration test...")
    let testFileURL = SettingsController.sottoDataURL.appendingPathComponent("bridge_audit.jsonl")
    
    let fm = FileManager.default
    let originalExists = fm.fileExists(atPath: testFileURL.path)
    let originalContent = (try? String(contentsOf: testFileURL, encoding: .utf8)) ?? ""
    
    BridgeAudit.record(
        outcome: .delegated,
        transcript: "Jarvis run test",
        command: "run test",
        app: "SottoTest",
        reply: "Executed successfully",
        latencyMs: 15.0
    )
    
    let start = Date()
    var verified = false
    while Date().timeIntervalSince(start) < 2.0 {
        if let newContent = try? String(contentsOf: testFileURL, encoding: .utf8),
           newContent.contains("run test") {
            verified = true
            break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    
    if !verified {
        print("❌ BridgeAudit integration test: FAILED (record did not write to file)")
        return false
    }
    
    let summary = BridgeAudit.summary()
    print("[TEST] BridgeAudit summary: \(summary)")
    if !summary.contains("delegated") {
        print("❌ BridgeAudit integration test: FAILED (summary is incorrect)")
        return false
    }
    
    let recent = BridgeAudit.recent(limit: 1)
    print("[TEST] BridgeAudit recent: \(recent)")
    if !recent.contains("run test") {
        print("❌ BridgeAudit integration test: FAILED (recent output incorrect)")
        return false
    }
    
    if originalExists {
        try? originalContent.write(to: testFileURL, atomically: true, encoding: .utf8)
    } else {
        try? fm.removeItem(at: testFileURL)
    }
    
    print("✅ BridgeAudit integration test: PASSED")
    return true
}

public func runSottoIntegrationTests() async -> Bool {
    print("=== STARTING SOTTO INTEGRATION TESTS ===")
    var success = await runCoordinatorAgentIntegrationTest()
    if success { success = await runCapabilityConsistencyCheck() }
    if success { success = runDynamicSkillTriggerTest() }
    if success { success = runBridgeAuditIntegrationTest() }
    if success {
        print("[TEST] Verifying JarvisEvaluation runner (forceMock)...")
        success = await JarvisEvaluation.run(forceMock: true)
    }
    if success {
        print("=== ALL INTEGRATION TESTS PASSED ===")
    } else {
        print("=== INTEGRATION TESTS FAILED ===")
    }
    return success
}
#endif
