import Cocoa
import CoreGraphics

struct NativeClipboard {
    static func get() -> String {
        return NSPasteboard.general.string(forType: .string) ?? ""
    }
    
    static func set(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct WindowManager {
    static func getRunningApps() -> [String] {
        let apps = NSWorkspace.shared.runningApplications
        return apps.filter { $0.activationPolicy == .regular }.compactMap { app in
            guard let name = app.localizedName else { return nil }
            return "\(name) (PID: \(app.processIdentifier))"
        }
    }
    
    static func activateApp(pid: Int32) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            return false
        }
        return app.activate(options: [])
    }
    
    static func getWindowList() -> [String] {
        var windowNames: [String] = []
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return []
        }
        for info in windowListInfo {
            if let ownerName = info[kCGWindowOwnerName as String] as? String,
               let windowName = info[kCGWindowName as String] as? String,
               !windowName.isEmpty {
                windowNames.append("\(ownerName): \(windowName)")
            }
        }
        return windowNames
    }
}

struct KeySimulator {
    // US Keyboard Layout virtual keycodes
    private static let keyMap: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "escape": 53, "delete": 51,
        "left": 123, "right": 124, "down": 125, "up": 126,
        // Common spoken aliases so the model's natural words map correctly.
        "esc": 53, "enter": 36, "del": 51, "backspace": 51, "spacebar": 49,
        "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126
    ]
    
    static func simulate(key: String, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) async -> Bool {
        guard let code = keyMap[key.lowercased()] else {
            print("[KEY-SIMULATOR] Unknown key name: \(key)")
            return false
        }
        
        var flags = CGEventFlags()
        if cmd { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if opt { flags.insert(.maskAlternate) }
        if ctrl { flags.insert(.maskControl) }
        
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            return false
        }
        
        down.flags = flags
        up.flags = flags
        
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(25)) // 25ms delay
        up.post(tap: .cghidEventTap)
        return true
    }
}
