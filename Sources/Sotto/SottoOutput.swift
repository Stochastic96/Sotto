import AppKit
import AVFoundation
import Vision
import ScreenCaptureKit
import ApplicationServices
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - SottoOutput
//
// Single actor for ALL outputs: HUD display, TTS, text injection, screen reading.
// Subscribes to engineResult / engineError on the EventBus.
// NSPanel must be touched on @MainActor — bridged internally.

@MainActor
final class SottoOutput {
    static let shared = SottoOutput()

    private let hud = SottoHUD()
    private let synth = AVSpeechSynthesizer()
    private let injector = TextInjector()      // existing — keep as-is

    // MARK: - Lifecycle

    func start() {
        Task { await listenForResults() }
    }

    private func listenForResults() async {
        for await event in await EventBus.shared.makeStream() {
            switch event {
            case .processingStarted(let mode):
                hud.show(mode == .dictation ? "●  Listening…" : "✨  Jarvis…")
            case .transcribed(let text):
                hud.show("…  \(text.prefix(50))")
            case .engineResult(let r):
                handleResult(r)
            case .engineError(let msg):
                hud.show("⚠️ \(msg)")
                speak("Something went wrong.")
                dismissHUD(after: 3)
            case .hudWillShow: break
            case .hudDidHide:  break
            default: break
            }
        }
    }

    // MARK: - HUD

    func show(_ text: String)  { hud.show(text) }
    func hideHUD()             { hud.hide() }

    func dismissHUD(after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            hud.hide()
        }
    }

    // MARK: - TTS

    func speak(_ text: String) {
        guard SettingsController.isVoiceFeedbackEnabled, !text.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = preferredVoice()
        u.rate  = SettingsController.speechRate
        synth.speak(u)
    }

    func stopSpeaking() { synth.stopSpeaking(at: .immediate) }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        // Daniel (British) sounds most like JARVIS; fall back through a priority list
        let preferred = ["Daniel", "Alex", "Samantha"]
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-") }
        for name in preferred {
            if let v = voices.first(where: { $0.name.lowercased().contains(name.lowercased()) }) {
                return v
            }
        }
        return voices.first(where: { $0.gender == .male }) ?? voices.first
    }

    // MARK: - Text injection

    func inject(_ text: String, targetPID: pid_t?) async {
        guard !text.isEmpty else { return }
        await injector.inject(text, fileURL: nil, targetPID: targetPID)
    }

    // MARK: - Screen reader (ScreenCaptureKit → Vision OCR)

    func readScreen() async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let cfg = SCStreamConfiguration()
            cfg.width = 1920; cfg.height = 1080
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return await ocrImage(img)
        } catch {
            print("[OUTPUT] Screen capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func ocrImage(_ image: CGImage) async -> String? {
        await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                let text = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                cont.resume(returning: text.map { $0.isEmpty ? nil : $0 } ?? nil)
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([req])
        }
    }

    // MARK: - Selection grabber (AX API)

    func grabSelection(targetPID: pid_t?) -> String? {
        guard let pid = targetPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var focusedEl: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedEl) == .success,
              let el = focusedEl else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement,
              kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Apple Intelligence summarise

    func summarise(_ text: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession()
            let prompt  = "Summarise in 1–2 sentences:\n\n\(text)"
            return (try? await session.respond(to: prompt).content) ?? text
        }
        #endif
        return text
    }

    // MARK: - Result presentation

    private func handleResult(_ r: EventBus.EngineResult) {
        if let inject = r.injectText, !inject.isEmpty {
            // Dictation path — inject text, show brief confirmation
            hud.show("✓ \(inject.prefix(60))")
        } else if !r.reply.isEmpty {
            hud.showResult(r.reply)
            speak(shortSpoken(r.reply))
        } else {
            hud.show("✓ Done")
        }
        dismissHUD(after: r.reply.count > 100 ? 4 : 2.5)
    }

    private func shortSpoken(_ text: String) -> String {
        let line  = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let chunk = line.split(separator: ",", maxSplits: 1).first.map(String.init) ?? line
        let t = chunk.trimmingCharacters(in: .whitespaces)
        return t.count <= 80 ? t : String(t.prefix(80))
    }
}

// MARK: - SottoHUD
// Thin @MainActor wrapper so HUDOverlay can be touched from the SottoOutput @MainActor class.

@MainActor
private final class SottoHUD {
    private let overlay = HUDOverlay()
    func show(_ text: String) { overlay.show(text) }
    func showResult(_ text: String) { overlay.showResult(text) }
    func hide() { overlay.hide() }
}
