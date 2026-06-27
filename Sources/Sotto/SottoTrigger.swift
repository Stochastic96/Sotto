import AppKit
import Speech
import AVFoundation
import AppIntents
import KeyboardShortcuts

// MARK: - SottoTrigger
//
// Single actor that owns ALL entry points into the system.
// Fires EventBus events; has no knowledge of Engine or Output.
//
// Entry points:
//   1. Global hotkeys (KeyboardShortcuts package)
//   2. "Hey Jarvis" wake word (SFSpeechRecognizer, requiresOnDeviceRecognition)
//   3. App Intents / Siri / Shortcuts (SottoIntent)
//   4. URL scheme  sotto://command?text=...

extension KeyboardShortcuts.Name {
    static let dictation = Self("sotto.dictation", default: .init(.k, modifiers: [.command, .shift]))
    static let assistant  = Self("sotto.assistant",  default: .init(.j, modifiers: [.command, .shift]))
}

@MainActor
final class SottoTrigger {
    static let shared = SottoTrigger()

    private var wakeSession: WakeSession?
    private var suspended = false

    // MARK: - Lifecycle

    func start() {
        bindHotkeys()
        startWakeWord()
        observeURLScheme()
    }

    func suspend() { suspended = true;  wakeSession?.stop() }
    func resume()  { suspended = false; startWakeWord() }

    // MARK: - Hotkeys

    private func bindHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
            guard self?.suspended == false else { return }
            Task { await EventBus.shared.emit(.hotkeyPressed(mode: .dictation)) }
        }
        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
            guard self?.suspended == false else { return }
            Task { await EventBus.shared.emit(.hotkeyReleased(mode: .dictation)) }
        }
        KeyboardShortcuts.onKeyDown(for: .assistant) { [weak self] in
            guard self?.suspended == false else { return }
            Task { await EventBus.shared.emit(.hotkeyPressed(mode: .assistant)) }
        }
        KeyboardShortcuts.onKeyUp(for: .assistant) { [weak self] in
            guard self?.suspended == false else { return }
            Task { await EventBus.shared.emit(.hotkeyReleased(mode: .assistant)) }
        }
    }

    // MARK: - Wake word ("Hey Jarvis" / "Jarvis" / "Sotto")

    private func startWakeWord() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        let session = WakeSession { [weak self] in
            Task { @MainActor in
                guard self?.suspended == false else { return }
                await EventBus.shared.emit(.wakeWordDetected)
                // Restart after brief delay so it's ready for the next command
                try? await Task.sleep(for: .seconds(3))
                self?.startWakeWord()
            }
        }
        session.start()
        wakeSession = session
    }

    // MARK: - URL scheme  sotto://command?text=...

    private func observeURLScheme() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SottoIncomingCommand"),
            object: nil, queue: .main
        ) { notification in
            guard let text = notification.userInfo?["text"] as? String, !text.isEmpty else { return }
            Task { await EventBus.shared.emit(.externalCommand(text)) }
        }
    }
}

// MARK: - WakeSession (private)
// Wraps SFSpeechRecognizer so SottoTrigger stays focused.

private final class WakeSession {
    private let recognizer: SFSpeechRecognizer
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let onDetected: () -> Void

    init(onDetected: @escaping () -> Void) {
        self.recognizer  = SFSpeechRecognizer(locale: .init(identifier: "en-US"))!
        self.onDetected  = onDetected
    }

    func start() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        let e = AVAudioEngine()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults     = true
        r.requiresOnDeviceRecognition    = true

        e.inputNode.installTap(onBus: 0, bufferSize: 1024,
                               format: e.inputNode.outputFormat(forBus: 0)) { buf, _ in r.append(buf) }
        try? e.start()
        engine  = e
        request = r

        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            if let t = result?.bestTranscription.formattedString.lowercased(),
               t.contains("jarvis") || t.contains("sotto") {
                self.stop()
                self.onDetected()
                return
            }
            if let err = error as NSError?,
               err.code != 301, err.domain != "kAFAssistantErrorDomain" {
                self.restart()
            }
        }
        print("[TRIGGER] Wake word armed — listening for 'Hey Jarvis'")
    }

    func stop() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if let e = engine, e.isRunning {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
    }

    private func restart() {
        stop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.start()
        }
    }
}

// MARK: - App Intent (Siri / Shortcuts entry point)

struct SottoAssistantIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Jarvis"
    static var description = IntentDescription("Run a command through Sotto's Jarvis agent.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Command")
    var command: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await EventBus.shared.emit(.externalCommand(command))
        // Give the engine up to 8s to reply; poll the bus for the result.
        for await event in await EventBus.shared.makeStream() {
            if case .engineResult(let r) = event {
                return .result(dialog: IntentDialog(stringLiteral: r.reply.isEmpty ? "Done." : r.reply))
            }
            if case .engineError(let msg) = event {
                throw NSError(domain: "Sotto", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
        return .result(dialog: "Done.")
    }
}

struct SottoDictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate with Sotto"
    static var description = IntentDescription("Transcribe speech and paste polished text.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Text to polish and insert")
    var text: String

    func perform() async throws -> some IntentResult {
        await EventBus.shared.emit(.externalCommand("dictate: \(text)"))
        return .result()
    }
}
