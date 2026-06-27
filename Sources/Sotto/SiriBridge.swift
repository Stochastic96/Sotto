import AppKit
import CoreGraphics

/// Fires a prompt into the macOS "Type to Siri" / Apple Intelligence box: simulate the
/// Siri activation shortcut, wait for the box to appear, paste the prompt, press Return.
///
/// This is deliberately FIRE-AND-FORGET. Siri answers in its OWN window and Sotto cannot
/// read the result back — but that's the point: it taps Siri's web answers, rich info
/// cards, and app actions that the bare on-device Foundation Models API does not have.
///
/// Requirements:
///  • Accessibility permission (to post synthetic keystrokes).
///  • "Type to Siri" enabled (System Settings ▸ Apple Intelligence & Siri).
///  • The Siri keyboard shortcut set to match the simulated combo. Default: Globe/fn + S
///    (a real built-in option, and unlike the double-Command default it CAN be simulated).
///    Override via the `sotto_siri_*` defaults if you use a custom shortcut.
enum SiriBridge {
    private static let injector = TextInjector()

    /// Just open the Siri box (no prompt).
    @MainActor
    static func openOnly() async {
        activate()
    }

    /// Open Siri, type `prompt`, and submit.
    @MainActor
    static func send(_ prompt: String) async {
        activate()
        let focused = await waitForSiriFocus()
        if !focused {
            // Fallback sleep if focus detection fails or is slow
            try? await Task.sleep(for: .milliseconds(400))
        }
        await injector.inject(prompt, fileURL: nil)        // pasteboard + ⌘V (reused)
        try? await Task.sleep(for: .milliseconds(150))
        await injector.pressReturn()
    }

    /// Polls frontmostApplication until Siri becomes the active focused window.
    @MainActor
    static func waitForSiriFocus(timeout: TimeInterval = 2.0) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier == "com.apple.Siri" || front.localizedName?.lowercased().contains("siri") == true {
                return true
            }
            try? await Task.sleep(for: .milliseconds(30)) // check every 30ms
        }
        return false
    }

    /// Waits until Siri has gained focus and then subsequently lost focus (dismissed or switched away).
    @MainActor
    static func waitForSiriDismiss(timeout: TimeInterval = 15.0) async {
        _ = await waitForSiriFocus(timeout: 2.0)
        try? await Task.sleep(for: .milliseconds(500)) // ensure Siri window is fully active
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let front = NSWorkspace.shared.frontmostApplication {
                let isSiri = front.bundleIdentifier == "com.apple.Siri" || front.localizedName?.lowercased().contains("siri") == true
                if !isSiri {
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(100)) // check every 100ms
        }
    }

    /// Simulate the Siri activation shortcut. Defaults to Globe/fn + S; every part is
    /// overridable via UserDefaults so a custom Siri shortcut still works.
    static func activate() {
        let d = UserDefaults.standard
        let keyCode = CGKeyCode(d.object(forKey: "sotto_siri_keycode") as? Int ?? 1) // 1 = 'S'
        var flags: CGEventFlags = []
        if (d.object(forKey: "sotto_siri_fn")    as? Bool) ?? true  { flags.insert(.maskSecondaryFn) }
        if (d.object(forKey: "sotto_siri_cmd")   as? Bool) ?? false { flags.insert(.maskCommand) }
        if (d.object(forKey: "sotto_siri_opt")   as? Bool) ?? false { flags.insert(.maskAlternate) }
        if (d.object(forKey: "sotto_siri_ctrl")  as? Bool) ?? false { flags.insert(.maskControl) }
        if (d.object(forKey: "sotto_siri_shift") as? Bool) ?? false { flags.insert(.maskShift) }

        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
