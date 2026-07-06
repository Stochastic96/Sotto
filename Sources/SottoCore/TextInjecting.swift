import Foundation

/// Which app-search shortcut to post. Lives here (not in CommandEngine) so both the
/// `TextInjecting` seam and the command layer can share it from SottoCore.
public enum SearchShortcutType: String, Sendable {
    case find      // Cmd+F
    case location  // Cmd+L
}

/// Abstracts text and selection injection into the focused application.
/// Conform to this protocol to substitute a test double or an alternative
/// injection strategy without touching call sites in AppController/CommandEngine.
///
/// Declared in SottoCore (Foundation-only) so the SottoTests target can inject a fake
/// injector and assert on what would have been typed — without driving real AX/pasteboard
/// side effects. The concrete `TextInjector` (AppKit/CoreGraphics) lives in the Sotto target.
public protocol TextInjecting: Sendable {
    func inject(_ text: String, fileURL: URL?, targetPID: pid_t?) async
    func injectUnicode(_ text: String, targetPID: pid_t?) async
    func grabActiveSelection(targetPID: pid_t?) async -> String?
    func pressReturn(targetPID: pid_t?) async
    func pressSearchShortcut(_ type: SearchShortcutType, targetPID: pid_t?) async
}

extension TextInjecting {
    public func inject(_ text: String, fileURL: URL? = nil, targetPID: pid_t? = nil) async {
        await inject(text, fileURL: fileURL, targetPID: targetPID)
    }
    public func injectUnicode(_ text: String, targetPID: pid_t? = nil) async {
        await injectUnicode(text, targetPID: targetPID)
    }
    public func grabActiveSelection() async -> String? { await grabActiveSelection(targetPID: nil) }
    public func pressReturn() async { await pressReturn(targetPID: nil) }
}
