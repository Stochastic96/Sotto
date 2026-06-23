import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self(
        "toggleDictation",
        default: KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
    )
    static let toggleJarvis = Self(
        "toggleJarvis",
        default: KeyboardShortcuts.Shortcut(.j, modifiers: [.command, .shift])
    )
}

/// Global hotkey listener using KeyboardShortcuts library.
/// Stores/loads shortcut from UserDefaults automatically.
final class HotkeyListener {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onJarvisPress: () -> Void
    private let onJarvisRelease: () -> Void

    init(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onJarvisPress: @escaping () -> Void,
        onJarvisRelease: @escaping () -> Void
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onJarvisPress = onJarvisPress
        self.onJarvisRelease = onJarvisRelease
    }

    func start() {
        print("[SOTTO] HotkeyListener.start() called")

        print("[SOTTO] Registering toggleDictation handlers...")
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            print("[SOTTO] *** DICTATION HOTKEY PRESSED ***")
            self?.onPress()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            print("[SOTTO] *** DICTATION HOTKEY RELEASED ***")
            self?.onRelease()
        }

        print("[SOTTO] Registering toggleJarvis handlers...")
        KeyboardShortcuts.onKeyDown(for: .toggleJarvis) { [weak self] in
            print("[SOTTO] *** JARVIS HOTKEY PRESSED ***")
            self?.onJarvisPress()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleJarvis) { [weak self] in
            print("[SOTTO] *** JARVIS HOTKEY RELEASED ***")
            self?.onJarvisRelease()
        }

        print("[SOTTO] Global hotkey listeners started (waiting for shortcut presses)")
    }

    func stop() {
        // Handlers are automatically cleaned up
    }
}
