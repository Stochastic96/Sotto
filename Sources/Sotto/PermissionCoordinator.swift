import AppKit
import AVFoundation
import Speech

// MARK: - PermissionCoordinator
//
// Requests every required permission in a clear, sequential order on first launch.
// Shows a single setup window so the user sees what's coming and why.
// After all permissions are granted, sets a UserDefaults flag so this never runs again.
//
// Permissions Sotto needs (in order):
//   1. Microphone          — voice input
//   2. Speech Recognition  — on-device ASR (SFSpeechRecognizer)
//   3. Accessibility       — global hotkey + ⌘V text injection
//   4. Screen Recording    — OCR / screen reading

@MainActor
final class PermissionCoordinator {
    static let shared = PermissionCoordinator()
    private static let doneKey = "sotto_permissions_granted_v2"

    // MARK: - Entry point

    /// Call once from AppController.start(). Runs the full setup flow if any
    /// permission is missing; otherwise just verifies and logs.
    func ensurePermissions() async {
        if allGranted() {
            logStatus()
            return
        }
        await runSetupFlow()
    }

    // MARK: - Flow

    private func runSetupFlow() async {
        // Show setup window first so the user knows what to expect
        let win = SetupWindow()
        win.show(step: "Getting started…", detail: "Sotto needs a few permissions to work. Each will ask once.")

        // 1. Microphone
        win.show(step: "1 of 4 — Microphone", detail: "So Sotto can hear your voice commands.")
        let micGranted = await requestMicrophone()
        if !micGranted {
            win.show(step: "⚠️ Microphone denied",
                     detail: "Go to System Settings → Privacy → Microphone and enable Sotto, then re-launch.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }

        // 2. Speech Recognition
        win.show(step: "2 of 4 — Speech Recognition", detail: "For on-device transcription without the cloud.")
        await requestSpeechRecognition()   // if denied, ASR falls back to appleSpeech — non-fatal

        // 3. Accessibility
        win.show(step: "3 of 4 — Accessibility",
                 detail: "So Sotto can register global hotkeys and type text into any app.")
        let axGranted = requestAccessibility()   // shows system dialog
        if !axGranted {
            // App must re-launch after Accessibility is granted; tell the user
            win.show(step: "⚠️ Accessibility — re-launch needed",
                     detail: "Enable Sotto in System Settings → Privacy → Accessibility, then re-launch.")
            // Poll every 2s; once granted, continue automatically
            for _ in 0..<30 {                           // up to 60s
                try? await Task.sleep(for: .seconds(2))
                if AXIsProcessTrusted() { break }
            }
            if !AXIsProcessTrusted() { win.dismiss(); return }
        }

        // 4. Screen Recording
        win.show(step: "4 of 4 — Screen Recording", detail: "For reading text on screen with OCR.")
        requestScreenRecording()           // non-fatal if denied

        // Done
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        win.showDone()
        try? await Task.sleep(for: .seconds(2))
        win.dismiss()
        logStatus()
    }

    // MARK: - Individual requests

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:       return true
        case .notDetermined:    return await AVCaptureDevice.requestAccess(for: .audio)
        default:                return false
        }
    }

    private func requestSpeechRecognition() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // SFSpeechRecognizer invokes this completion on a background queue.
            // Mark it @Sendable so it does NOT inherit this @MainActor type's
            // isolation — otherwise Swift's dynamic isolation check traps
            // (EXC_BREAKPOINT) when the closure runs off the main thread.
            // CheckedContinuation.resume() is safe to call from any executor.
            SFSpeechRecognizer.requestAuthorization { @Sendable _ in cont.resume() }
        }
    }

    @discardableResult
    private func requestAccessibility() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Helpers

    func allGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
        AXIsProcessTrusted()
        // Screen Recording and Speech Recognition are checked at use-time
    }

    private func logStatus() {
        let mic  = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "✅" : "❌"
        let sp   = SFSpeechRecognizer.authorizationStatus() == .authorized ? "✅" : "⚠️"
        let ax   = AXIsProcessTrusted() ? "✅" : "❌"
        let scr  = CGPreflightScreenCaptureAccess() ? "✅" : "⚠️"
        print("[PERM] Mic:\(mic) Speech:\(sp) AX:\(ax) Screen:\(scr)")
    }
}

// MARK: - SetupWindow
// A minimal NSPanel that shows progress during the permission setup flow.

@MainActor
private final class SetupWindow {
    private var panel: NSPanel?
    private var stepLabel: NSTextField?
    private var detailLabel: NSTextField?

    func show(step: String, detail: String) {
        if panel == nil { build() }
        stepLabel?.stringValue   = step
        detailLabel?.stringValue = detail
        panel?.orderFront(nil)
    }

    func showDone() {
        show(step: "✅ All set!", detail: "Sotto is ready. Use ⌘⇧K to dictate, ⌘⇧J for Jarvis.")
    }

    func dismiss() { panel?.close(); panel = nil }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
            styleMask:   [.titled, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        p.title          = "Sotto Setup"
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.97)
        p.center()
        p.level          = .floating

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let sl = NSTextField(labelWithString: "")
        sl.font      = .systemFont(ofSize: 15, weight: .semibold)
        sl.textColor = .white
        sl.cell?.wraps = true
        stepLabel = sl

        let dl = NSTextField(labelWithString: "")
        dl.font      = .systemFont(ofSize: 12)
        dl.textColor = NSColor(white: 0.7, alpha: 1)
        dl.cell?.wraps = true
        detailLabel = dl

        stack.addArrangedSubview(sl)
        stack.addArrangedSubview(dl)
        p.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: p.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: p.contentView!.bottomAnchor),
        ])
        panel = p
    }
}
