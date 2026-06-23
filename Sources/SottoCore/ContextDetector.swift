import AppKit

public struct AppContext {
    public let bundleID: String
    public let appName: String
    public let style: FormattingStyle
}

public enum FormattingStyle {
    /// Code editors and terminals — inject exactly what was said, no cleanup.
    case verbatim
    /// Chat apps — drop the trailing period, keep it casual.
    case chat
    /// Everything else — trust the model's punctuation as-is.
    case prose

    public func apply(to text: String) -> String {
        switch self {
        case .verbatim, .prose:
            return text
        case .chat:
            var t = text
            if t.hasSuffix(".") && !t.hasSuffix("...") {
                t.removeLast()
            }
            return t
        }
    }
}

public enum ContextDetector {
    private static let codeApps: Set<String> = [
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.zed.Zed",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.sublimetext.4",
        "com.jetbrains.intellij",
    ]

    private static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
        "com.hnc.Discord",
        "com.facebook.archon", // Messenger
    ]

    // Cache invalidated whenever the frontmost app changes.
    // nonisolated(unsafe) is safe here: always written/read on Main.
    nonisolated(unsafe) private static var _cached: AppContext?

    /// Subscribe to app-switch notifications so `currentCached()` is always fresh.
    /// Call once at app startup (e.g. in AppController.start()).
    public static func startObservingAppSwitches() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            _cached = nil
        }
    }

    /// Like `current()` but returns a cached result if the frontmost app hasn't changed,
    /// avoiding a redundant NSWorkspace query on every keystroke/dictation call.
    public static func currentCached() -> AppContext {
        if let c = _cached { return c }
        let fresh = current()
        _cached = fresh
        return fresh
    }

    public static func current() -> AppContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        let name = app?.localizedName ?? "Unknown"

        let style: FormattingStyle
        if codeApps.contains(bundleID) {
            style = .verbatim
        } else if chatApps.contains(bundleID) {
            style = .chat
        } else {
            style = .prose
        }
        return AppContext(bundleID: bundleID, appName: name, style: style)
    }
}
