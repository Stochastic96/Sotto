import AppKit

struct AppContext {
    let bundleID: String
    let appName: String
    let style: FormattingStyle
}

enum FormattingStyle {
    /// Code editors and terminals — inject exactly what was said, no cleanup.
    case verbatim
    /// Chat apps — drop the trailing period, keep it casual.
    case chat
    /// Everything else — trust the model's punctuation as-is.
    case prose

    func apply(to text: String) -> String {
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

enum ContextDetector {
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

    static func current() -> AppContext {
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
