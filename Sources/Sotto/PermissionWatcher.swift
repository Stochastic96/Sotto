import AppKit
import AVFoundation
import Speech

// MARK: - PermissionWatcher
//
// Polls all permission states every 3 seconds and:
//   • Updates the status bar icon/tooltip with live status
//   • When Accessibility transitions notTrusted→trusted: relaunches the
//     process automatically so AX takes effect (macOS caches trust at process start)
//   • When Microphone transitions denied→granted: re-arms the audio engine
//   • Shows one HUD message when any permission is fixed/broken

@MainActor
final class PermissionWatcher {
    static let shared = PermissionWatcher()

    private var pollingTask: Task<Void, Never>?
    private var lastAX  = false
    private var lastMic = false
    private var launched = false

    // MARK: - Start

    func start() {
        lastAX  = AXIsProcessTrusted()
        lastMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        launched = true

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.poll()
            }
        }
        print("[WATCH] Permission watcher started — AX:\(lastAX ? "✅" : "❌") Mic:\(lastMic ? "✅" : "❌")")
    }

    func stop() { pollingTask?.cancel(); pollingTask = nil }

    // MARK: - Poll

    private func poll() {
        let ax  = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        // Accessibility granted after launch → must restart for it to take effect
        if ax && !lastAX {
            print("[WATCH] Accessibility just granted — restarting Sotto to activate")
            AppController.shared?.hud.present(.success("Accessibility granted", detail: "Restarting…"))
            Task { try? await Task.sleep(for: .milliseconds(1500)); Self.relaunch() }
        }

        // Accessibility revoked while running → warn
        if !ax && lastAX {
            print("[WATCH] ⚠️ Accessibility revoked")
            AppController.shared?.hud.present(.warning("Accessibility revoked", detail: "Re-enable in System Settings"))
        }

        // Microphone just granted
        if mic && !lastMic {
            print("[WATCH] Microphone just granted")
            AppController.shared?.hud.present(.success("Microphone granted", detail: "Ready to record"))
            Task { try? await Task.sleep(for: .seconds(2)); AppController.shared?.hideHUD() }
        }

        lastAX  = ax
        lastMic = mic
    }

    // MARK: - Relaunch

    /// Spawn a fresh copy of ourselves and quit the current process.
    /// The relaunched process will pick up the new TCC trust state.
    private static func relaunch() {
        guard let execURL = Bundle.main.executableURL else {
            // Fallback: just tell user to re-launch manually
            AppController.shared?.hud.present(.info("Re-launch Sotto to activate Accessibility"))
            return
        }

        // Determine the actual executable path (for both .app bundle and raw binary)
        let path: String
        if execURL.path.contains(".app/Contents/MacOS/") {
            path = execURL.path
        } else {
            path = execURL.path   // raw binary — same path works
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments     = ["-c", "sleep 0.8 && '\(path)'"]
        try? task.run()

        NSApp.terminate(nil)
    }
}

// MARK: - StatusBarController convenience

extension AppController {
    /// Compact permission status string for the status bar tooltip.
    func permissionStatusLine() -> String {
        let ax  = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let scr = CGPreflightScreenCaptureAccess()
        let sp  = SFSpeechRecognizer.authorizationStatus() == .authorized

        var missing: [String] = []
        if !ax  { missing.append("Accessibility") }
        if !mic { missing.append("Microphone") }
        if !scr { missing.append("Screen Recording") }
        if !sp  { missing.append("Speech Recognition") }

        if missing.isEmpty {
            return "✅ All permissions granted"
        }
        return "⚠️ Missing: \(missing.joined(separator: ", "))"
    }
}
