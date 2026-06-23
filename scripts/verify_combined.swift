import Foundation
import AppKit
import ApplicationServices

public let kAXFrameAttribute = "AXFrame"

public func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<AnyObject?>) -> AXError {
    if (attribute as String) == kAXFrameAttribute {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        var position = CGPoint.zero
        var size = CGSize.zero
        
        let posStatus = ApplicationServices.AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sizeStatus = ApplicationServices.AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        
        if posStatus == .success, let posVal = posValue {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        }
        if sizeStatus == .success, let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }
        
        var rect = CGRect(origin: position, size: size)
        if let rectValue = AXValueCreate(.cgRect, &rect) {
            value.pointee = rectValue as AnyObject
            return .success
        }
        return .failure
    } else {
        return ApplicationServices.AXUIElementCopyAttributeValue(element, attribute, value)
    }
}

public struct AXNode: Codable {
    public let role: String
    public let title: String?
    public let value: String?
    public let identifier: String?
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public class ScreenParser {
    private static var elementCache: [Int: AXUIElement] = [:]
    private static var nextId = 1

    public static func clearCache() {
        elementCache.removeAll()
        nextId = 1
    }

    public static func captureActiveWindowTree() -> String {
        clearCache()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "No active application found."
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        var focusedWindow: AnyObject?
        let status = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        
        let windowElement: AXUIElement
        if status == .success, let win = focusedWindow {
            windowElement = win as! AXUIElement
        } else {
            var windowsValue: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement], let first = windows.first {
                windowElement = first
            } else {
                return "No active window found for \(app.localizedName ?? "app")."
            }
        }

        var markup = "Active Window of \(app.localizedName ?? "App"):\n"
        traverse(element: windowElement, depth: 0, maxDepth: 8, markup: &markup)
        return markup
    }

    private static func traverse(element: AXUIElement, depth: Int, maxDepth: Int, markup: inout String) {
        guard depth <= maxDepth else { return }

        var roleValue: AnyObject?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? "Unknown"

        var titleValue: AnyObject?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        let title = titleValue as? String

        var valValue: AnyObject?
        _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valValue)
        let value = valValue as? String

        var frameValue: AnyObject?
        var frame = CGRect.zero
        if AXUIElementCopyAttributeValue(element, kAXFrameAttribute as CFString, &frameValue) == .success {
            AXValueGetValue(frameValue as! AXValue, .cgRect, &frame)
        }

        let isInteractive = isInteractiveRole(role) || (role == "AXStaticText" && !(title ?? "").isEmpty)

        if isInteractive {
            let id = nextId
            elementCache[id] = element
            nextId += 1

            let label = title ?? ""
            let valStr = value != nil ? " Value: \"\(value!)\"" : ""
            markup += "[\(id)] \(role.replacingOccurrences(of: "AX", with: "")): \"\(label)\"\(valStr) [x: \(frame.origin.x), y: \(frame.origin.y), w: \(frame.size.width), h: \(frame.size.height)]\n"
        }

        var childrenValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                traverse(element: child, depth: depth + 1, maxDepth: maxDepth, markup: &markup)
            }
        }
    }

    private static func isInteractiveRole(_ role: String) -> Bool {
        let roles = ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXComboBox"]
        return roles.contains(role)
    }

    public static func performClick(id: Int) -> Bool {
        guard let element = elementCache[id] else { return false }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return result == .success
    }

    public static func performSetValue(id: Int, value: String) -> Bool {
        guard let element = elementCache[id] else { return false }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        return result == .success
    }
}

public struct ExecutionResult {
    public let success: Bool
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public class SwiftScriptRunner {
    public static func run(scriptCode: String) async -> ExecutionResult {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sotto_script_\(UUID().uuidString).swift"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try scriptCode.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return ExecutionResult(success: false, stdout: "", stderr: "Failed to write temp script: \(error.localizedDescription)", exitCode: -1)
        }
        
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [fileURL.path]
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            
            let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
            let stderrStr = String(data: errData, encoding: .utf8) ?? ""
            
            let success = (process.terminationStatus == 0)
            return ExecutionResult(success: success, stdout: stdoutStr, stderr: stderrStr, exitCode: process.terminationStatus)
        } catch {
            return ExecutionResult(success: false, stdout: "", stderr: "Failed to run swift process: \(error.localizedDescription)", exitCode: -1)
        }
    }
}

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
