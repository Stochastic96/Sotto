import Foundation
import AppKit
import ApplicationServices

func runTests() async {
    print("=== STARTING SOTTO CORE VERIFICATION ===")
    
    // 1. Verify SwiftScriptRunner
    print("Testing SwiftScriptRunner...")
    let testSnippet = """
    import Foundation
    print("Runner Test: OK")
    """
    
    let runnerResult = await SwiftScriptRunner.run(scriptCode: testSnippet)
    print("Runner Success: \(runnerResult.success)")
    print("Runner Exit Code: \(runnerResult.exitCode)")
    print("Runner Stdout: \(runnerResult.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
    print("Runner Stderr: \(runnerResult.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
    
    if runnerResult.success && runnerResult.stdout.contains("Runner Test: OK") {
        print("✅ SwiftScriptRunner Test: PASSED")
    } else {
        print("❌ SwiftScriptRunner Test: FAILED")
        exit(1)
    }
    
    // 2. Verify ScreenParser
    print("\nTesting ScreenParser...")
    let trusted = AXIsProcessTrusted()
    print("Accessibility permission trusted: \(trusted)")
    
    // Test cache clear
    ScreenParser.clearCache()
    print("Cleared ScreenParser cache.")
    
    let tree = ScreenParser.captureActiveWindowTree()
    print("Captured active window tree size: \(tree.count) characters")
    
    if trusted {
        // If trusted, we expect a real output
        print("Active window tree preview:")
        let lines = tree.split(separator: "\n")
        for line in lines.prefix(10) {
            print("  \(line)")
        }
        if lines.count > 10 {
            print("  ... (\(lines.count - 10) more lines)")
        }
    } else {
        // If not trusted, we expect a fallback string
        print("Tree result (Untrusted): \(tree)")
    }
    
    // Let's verify we can call performClick and performSetValue safely (should return false for invalid ID)
    let clickResult = ScreenParser.performClick(id: 9999)
    let setValueResult = ScreenParser.performSetValue(id: 9999, value: "test")
    print("Perform click on invalid ID: \(clickResult)")
    print("Perform set value on invalid ID: \(setValueResult)")
    
    if !clickResult && !setValueResult {
        print("✅ ScreenParser API Safety Test: PASSED")
    } else {
        print("❌ ScreenParser API Safety Test: FAILED")
        exit(1)
    }
    
    print("\n=== ALL SOTTO CORE VERIFICATION PASSED ===")
}

// Run the async block
let semaphore = DispatchSemaphore(value: 0)
Task {
    await runTests()
    semaphore.signal()
}
semaphore.wait()
