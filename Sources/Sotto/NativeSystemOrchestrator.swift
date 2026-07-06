import AppKit
import Foundation

/// Native system actions driven via `NSAppleScript` / Apple Events. `@MainActor`-isolated
/// because Apple Events must be dispatched on the main run loop — the isolation makes that a
/// compile-time guarantee rather than a convention every caller has to remember.
@MainActor
struct NativeSystemOrchestrator {

    static func lockScreen() {
        // Triggers the standard macOS Lock Screen action instantly
        let lib = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_NOW)
        if let sym = dlsym(lib, "SACLockScreenImmediate") {
            let SACLockScreenImmediate = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
            _ = SACLockScreenImmediate()
            print("[SYSTEM] Screen locked natively.")
        } else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSaverEngine") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
    
    static func emptyTrash() {
        // AppKit native NSAppleScript to empty trash without compiling scripting files repeatedly
        let appleScript = "tell application \"Finder\" to empty trash"
        if let script = NSAppleScript(source: appleScript) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                print("[SYSTEM] Empty Trash failed: \(error)")
            } else {
                print("[SYSTEM] Trash emptied natively.")
            }
        }
    }

    /// Flushes inactive memory and the disk cache. Requires admin auth — macOS shows
    /// a native password dialog via AppleScript's `with administrator privileges`.
    @discardableResult
    static func purgeRAM() -> Bool {
        let appleScript = "do shell script \"purge\" with administrator privileges"
        guard let script = NSAppleScript(source: appleScript) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            print("[SYSTEM] purge failed: \(error)")
            return false
        }
        print("[SYSTEM] RAM purged.")
        return true
    }

    /// Puts the Mac to sleep. No public Swift API exists, so this uses an in-process
    /// System Events command (no external script file, no shell).
    static func sleepDisplay() {
        let appleScript = "tell application \"System Events\" to sleep"
        if let script = NSAppleScript(source: appleScript) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error { print("[SYSTEM] Sleep failed: \(error)") }
        }
    }

    /// Creates a note in the Notes app. Notes has no public framework API, so this
    /// uses an in-process System Events / Notes command (no external script file).
    @discardableResult
    static func createNote(_ text: String) -> Bool {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "tell application \"Notes\" to make new note at folder \"Notes\" of account \"iCloud\" with properties {body:\"\(escaped)\"}"
        guard let script = NSAppleScript(source: appleScript) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            print("[SYSTEM] Create note failed: \(error)")
            // Fall back to the default account if iCloud isn't configured.
            let fallback = "tell application \"Notes\" to make new note with properties {body:\"\(escaped)\"}"
            if let s2 = NSAppleScript(source: fallback) {
                var e2: NSDictionary?
                s2.executeAndReturnError(&e2)
                return e2 == nil
            }
            return false
        }
        return true
    }
}
