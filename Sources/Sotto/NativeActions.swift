import AppKit
import ApplicationServices
import CoreGraphics

/// Pure-Swift replacements for what used to be external AppleScript `.scpt` files.
/// Everything here runs in-process via native macOS APIs — Accessibility (window
/// management), system-defined media keys, synthetic keystrokes (browser nav) and
/// CoreGraphics. No `osascript`, no shell, no bundled script files.
@MainActor
enum NativeActions {
    /// Performs a `native:<action>` command. Returns any text output (most actions
    /// return ""; `browser_list_tabs` returns the tab/window titles).
    static func perform(_ action: String) async -> String {
        switch action {
        // Window management (Accessibility API)
        case let a where a.hasPrefix("win_"):
            NativeWindow.perform(a)
            return ""

        // Media transport (works for Spotify, Music, browsers — any media app)
        case "media_play":  MediaControl.send(MediaControl.playPause); return ""
        case "media_next":  MediaControl.send(MediaControl.next);      return ""
        case "media_prev":  MediaControl.send(MediaControl.previous);  return ""

        // Browser control via synthetic keystrokes to the frontmost browser
        case "browser_reload":     _ = await KeySimulator.simulate(key: "r", cmd: true, shift: false, opt: false, ctrl: false); return ""
        case "browser_back":       _ = await KeySimulator.simulate(key: "[", cmd: true, shift: false, opt: false, ctrl: false); return ""
        case "browser_forward":    _ = await KeySimulator.simulate(key: "]", cmd: true, shift: false, opt: false, ctrl: false); return ""
        case "browser_new_tab":    _ = await KeySimulator.simulate(key: "t", cmd: true, shift: false, opt: false, ctrl: false); return ""
        case "browser_close_tab":  _ = await KeySimulator.simulate(key: "w", cmd: true, shift: false, opt: false, ctrl: false); return ""
        case "browser_list_tabs":  return BrowserControl.listFrontmostWindows()

        // System power / housekeeping
        case "sleep":        NativeSystemOrchestrator.sleepDisplay();  return ""
        case "lock":         NativeSystemOrchestrator.lockScreen();    return ""
        case "empty_trash":  NativeSystemOrchestrator.emptyTrash();    return ""
        case "purge_ram":    NativeSystemOrchestrator.purgeRAM();      return "RAM purged."

        // System status & diagnostics
        case "system_status":
            let battery = SystemDiagnostics.getBatteryPercentage()
            let wifi = SystemDiagnostics.getWifiSSID()
            let disk = SystemDiagnostics.getFreeDiskSpace()
            AppController.shared?.speak("System report ready. Battery at \(battery), Wi-Fi on \(wifi), free disk \(disk).")
            return "# System Status Report\n\n- **Battery**: \(battery)\n- **Wi-Fi SSID**: \(wifi)\n- **Free Disk Space**: \(disk)\n"
            
        case "ram_status":
            let ram = SystemDiagnostics.getRAMUsage()
            let hogs = SystemDiagnostics.getTopMemoryProcesses()
            var report = "# 🧠 RAM Memory Status\n\n"
            report += "- **Total RAM**: \(String(format: "%.2f", ram.totalGB)) GB\n"
            report += "- **Used RAM**: \(String(format: "%.2f", ram.totalGB - ram.freeGB)) GB (\(String(format: "%.1f", ram.usedPercent))%)\n"
            report += "- **Free RAM**: \(String(format: "%.2f", ram.freeGB)) GB\n"
            report += "- **Wired (System)**: \(String(format: "%.2f", ram.wiredGB)) GB\n"
            report += "- **Active (App)**: \(String(format: "%.2f", ram.activeGB)) GB\n"
            report += "- **Compressed**: \(String(format: "%.2f", ram.compressedGB)) GB\n\n"
            report += "## 🏆 Top Memory Consumers\n\n| Process Name | Memory Usage |\n| :--- | :--- |\n"
            report += hogs
            AppController.shared?.speak("Total RAM is \(String(format: "%.1f", ram.totalGB)) gigabytes. Used is \(String(format: "%.1f", ram.usedPercent)) percent.")
            return report

        // Appearance
        case "dark_mode_toggle": Appearance.toggleDarkMode(); return ""
        case "show_desktop":     Appearance.showDesktop();    return ""

        // Siri Integration
        case "open_siri":
            await SiriBridge.openOnly()
            return "Siri opened."

        case let a where a.hasPrefix("ask_siri:"):
            let query = String(a.dropFirst("ask_siri:".count))
            await SiriBridge.send(query)
            return "Sent query '\(query)' to Siri."

        // Parametric volume/brightness controls
        case let a where a.hasPrefix("set_volume:"):
            if let pct = Int(a.dropFirst("set_volume:".count)) {
                _ = SystemControlHelper.setVolume(Float(pct))
                return "Volume \(pct)%"
            }
            return ""

        case let a where a.hasPrefix("set_brightness:"):
            if let pct = Int(a.dropFirst("set_brightness:".count)) {
                _ = SystemControlHelper.setBrightness(Float(pct) / 100.0)
                return "Brightness \(pct)%"
            }
            return ""

        case "mute":            _ = SystemControlHelper.setMuted(true); return "Muted"
        case "unmute":          _ = SystemControlHelper.setMuted(false); return "Unmuted"
        case "volume_up":       _ = SystemControlHelper.setVolume(SystemControlHelper.getVolume() + 10.0); return "Volume Set"
        case "volume_down":     _ = SystemControlHelper.setVolume(SystemControlHelper.getVolume() - 10.0); return "Volume Set"
        case "brightness_up":   _ = SystemControlHelper.setBrightness(SystemControlHelper.getBrightness() + 0.1); return "Brightness Set"
        case "brightness_down": _ = SystemControlHelper.setBrightness(SystemControlHelper.getBrightness() - 0.1); return "Brightness Set"

        default:
            print("[NATIVE] Unknown native action: \(action)")
            return ""
        }
    }
}

// MARK: - Window management (Accessibility API)

@MainActor
enum NativeWindow {
    static func perform(_ action: String) {
        guard let win = focusedWindow() else {
            print("[NATIVE-WIN] No focused window for \(action)")
            return
        }
        if action == "win_minimize" {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return
        }
        if action == "win_close" {
            var btn: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &btn) == .success,
               let b = btn {
                AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
            }
            return
        }

        let wa = workArea()
        let halfW = wa.width / 2, halfH = wa.height / 2
        let rect: CGRect
        switch action {
        case "win_maximize":     rect = wa
        case "win_left":         rect = CGRect(x: wa.minX, y: wa.minY, width: halfW, height: wa.height)
        case "win_right":        rect = CGRect(x: wa.minX + halfW, y: wa.minY, width: halfW, height: wa.height)
        case "win_top_half":     rect = CGRect(x: wa.minX, y: wa.minY, width: wa.width, height: halfH)
        case "win_bottom_half":  rect = CGRect(x: wa.minX, y: wa.minY + halfH, width: wa.width, height: halfH)
        case "win_top_left":     rect = CGRect(x: wa.minX, y: wa.minY, width: halfW, height: halfH)
        case "win_top_right":    rect = CGRect(x: wa.minX + halfW, y: wa.minY, width: halfW, height: halfH)
        case "win_bottom_left":  rect = CGRect(x: wa.minX, y: wa.minY + halfH, width: halfW, height: halfH)
        case "win_bottom_right": rect = CGRect(x: wa.minX + halfW, y: wa.minY + halfH, width: halfW, height: halfH)
        case "win_small":        rect = centered(fraction: 0.5, in: wa)
        case "win_medium":       rect = centered(fraction: 0.7, in: wa)
        case "win_large":        rect = centered(fraction: 0.9, in: wa)
        case "win_center":
            let size = currentSize(win) ?? CGSize(width: halfW, height: halfH)
            rect = CGRect(x: wa.minX + (wa.width - size.width) / 2,
                          y: wa.minY + (wa.height - size.height) / 2,
                          width: size.width, height: size.height)
        default:
            return
        }
        setFrame(win, rect)
    }

    private static func centered(fraction: CGFloat, in wa: CGRect) -> CGRect {
        let w = wa.width * fraction, h = wa.height * fraction
        return CGRect(x: wa.minX + (wa.width - w) / 2, y: wa.minY + (wa.height - h) / 2, width: w, height: h)
    }

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var win: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
           let w = win {
            return (w as! AXUIElement)
        }
        var windows: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
           let arr = windows as? [AXUIElement], let first = arr.first {
            return first
        }
        return nil
    }

    private static func currentSize(_ win: AXUIElement) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &value) == .success,
              let rawValue = value else { return nil }
        var size = CGSize.zero
        AXValueGetValue(rawValue as! AXValue, .cgSize, &size)
        return size
    }

    private static func setFrame(_ win: AXUIElement, _ rect: CGRect) {
        var pos = rect.origin
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        }
        var size = rect.size
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    /// Visible work area in AX/global top-left coordinates (menu bar + Dock excluded).
    private static func workArea() -> CGRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let full = screen.frame
        let vis = screen.visibleFrame
        // Cocoa visibleFrame is bottom-left origin; AX wants top-left origin.
        let y = full.height - (vis.origin.y + vis.height)
        return CGRect(x: vis.origin.x, y: y, width: vis.width, height: vis.height)
    }
}

// MARK: - Media transport (system-defined NX keys)

@MainActor
enum MediaControl {
    static let playPause: Int32 = 16 // NX_KEYTYPE_PLAY
    static let next: Int32 = 17      // NX_KEYTYPE_NEXT
    static let previous: Int32 = 18  // NX_KEYTYPE_PREVIOUS

    static func send(_ keyType: Int32) {
        post(keyType, down: true)
        post(keyType, down: false)
    }

    private static func post(_ keyType: Int32, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let data1 = Int((keyType << 16) | ((down ? 0xA : 0xB) << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: data1, data2: -1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}

// MARK: - Browser helpers

@MainActor
enum BrowserControl {
    /// Lists the on-screen window titles of the frontmost app (best-effort tab list;
    /// the public APIs cannot enumerate per-tab titles of third-party browsers).
    static func listFrontmostWindows() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let owner = front.localizedName else { return "" }
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else { return "" }
        let titles = info.compactMap { dict -> String? in
            guard let o = dict[kCGWindowOwnerName as String] as? String, o == owner,
                  let name = dict[kCGWindowName as String] as? String, !name.isEmpty else { return nil }
            return name
        }
        return titles.joined(separator: "\n")
    }
}

// MARK: - Appearance

@MainActor
enum Appearance {
    /// Toggles system dark/light mode. There is no public Swift API for this; the
    /// only supported mechanism is an in-process System Events command (no file, no
    /// shell). Requires Automation permission for "System Events" on first use.
    static func toggleDarkMode() {
        let src = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        guard let script = NSAppleScript(source: src) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error { print("[NATIVE] Dark mode toggle failed: \(error)") }
    }

    /// Sends the "Show Desktop" key (F11 + Fn). Best-effort: respects the user's
    /// Mission Control shortcut being enabled.
    static func showDesktop() {
        let source = CGEventSource(stateID: .privateState)
        let f11: CGKeyCode = 103
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: f11, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: f11, keyDown: false) else { return }
        down.flags = .maskSecondaryFn
        up.flags = .maskSecondaryFn
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
