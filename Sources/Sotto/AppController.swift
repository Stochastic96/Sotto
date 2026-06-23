import AppKit
import AVFoundation
import Speech
import SottoCore

@MainActor final class AppController {
    static private(set) var shared: AppController?
    
    enum State {
        case loadingModel
        case idle
        case recording
        case transcribing
        case polishing
        case error(String)
    }

    private static let polishDefaultsKey = "aiPolishEnabled"

    let statusBar: StatusBarController
    let hud = HUDOverlay()
    let recorder = AudioRecorder()
    let transcriber = Transcriber()
    let injector = TextInjector()
    let speechSynthesizer = AVSpeechSynthesizer()
    var activeSound: NSSound?
    let settings = SettingsController()
    let explanationController = ExplanationWindowController()
    let promptReview = PromptReviewWindowController()
    var hotkey: HotkeyListener?
    var qwen: QwenRefiner?
    var polishEnabled: Bool
    let wakeDetector = WakeWordDetector()
    var visualizerTimer: Timer?
    var recordingStart: Date?
    var recentTranscripts: [String] = []
    var lastActiveApp: NSRunningApplication?
    var appActivity: NSObjectProtocol?
    var coordinator: AnyObject?

    enum Mode {
        case dictation
        case jarvis
    }
    // Default to dictation (Sotto's original behavior). Each hotkey sets its own mode on
    // press, so dictation and Jarvis stay completely separate.
    var currentMode: Mode = .dictation
    // Set while Jarvis is waiting for the answer to a clarifying ("ASK:") question.
    var pendingClarification = false

    var qwenRefiner: QwenRefiner? {
        return qwen
    }

    func showHUD(_ text: String) {
        hud.show(text)
    }

    func hideHUD() {
        hud.hide()
    }

    var state: State = .loadingModel {
        didSet {
            statusBar.update(for: state)
            updateWakeDetector()
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.polishDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.polishDefaultsKey)
        }
        polishEnabled = UserDefaults.standard.bool(forKey: Self.polishDefaultsKey)
        statusBar = StatusBarController(polishEnabled: polishEnabled)

        // Clean up corrupted/looping style examples from previous runs
        if let data = UserDefaults.standard.data(forKey: "sotto_style_examples"),
           let examples = try? JSONDecoder().decode([DictationExample].self, from: data) {
            let fillerWords = ["um", "uh", "ah", "umh", "blah", "something like that"]
            var cleaned = examples.filter { example in
                let lowerPolished = example.polished.lowercased()
                if fillerWords.contains(where: { lowerPolished.contains($0) }) {
                    return false
                }
                if hasRepetitiveLoops(example.polished) {
                    return false
                }
                let rawWords = example.raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                let polishedWords = example.polished.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                if rawWords.count >= 6 && Double(polishedWords.count) > Double(rawWords.count) * 2.5 {
                    return false
                }
                return true
            }
            // Trim to max 5 examples to keep context size manageable for 0.5B model
            if cleaned.count > 5 {
                cleaned = Array(cleaned.suffix(5))
            }
            if cleaned.count != examples.count {
                if let encoded = try? JSONEncoder().encode(cleaned) {
                    UserDefaults.standard.set(encoded, forKey: "sotto_style_examples")
                    print("[INIT] Cleaned up \(examples.count - cleaned.count) corrupted/looping style examples.")
                }
            }
        }

        // Self-heal the learned vocabulary: drop common words captured in error and
        // case-insensitive duplicates (keeping the better-cased variant). Sanitizes
        // lists saved before the stricter learning rules existed.
        let storedVocab = UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? []
        if !storedVocab.isEmpty {
            var byKey: [String: String] = [:]
            for term in storedVocab where !AppController.commonWordStopList.contains(term.lowercased()) {
                let key = term.lowercased()
                if let current = byKey[key] {
                    if term.filter({ $0.isUppercase }).count > current.filter({ $0.isUppercase }).count {
                        byKey[key] = term
                    }
                } else {
                    byKey[key] = term
                }
            }
            let cleanedVocab = byKey.values.sorted()
            if cleanedVocab != storedVocab.sorted() {
                UserDefaults.standard.set(cleanedVocab, forKey: "sotto_learned_vocabulary")
                print("[INIT] Cleaned learned vocabulary: \(storedVocab.count) → \(cleanedVocab.count) terms.")
            }
        }
        Self.shared = self
    }

    /// Nothing external to tear down — the brain (Apple Intelligence + in-process MLX)
    /// and TTS (AVSpeechSynthesizer) all run inside this process.
    func cleanup() {}

    func start() {
        print("[SOTTO-APP] AppController.start() called")

        // Prevent App Nap: Keep Sotto awake and responsive to global hotkeys and audio recording
        self.appActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Sotto needs to remain fully active to respond instantly to global hotkeys and record voice dictation."
        )

        // Cache app context so ContextDetector.currentCached() is zero-cost between app switches.
        ContextDetector.startObservingAppSwitches()

        statusBar.update(for: state)
        Task { await PermissionCoordinator.shared.ensurePermissions() }

        // Track the last active application before Sotto gets focus
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app != NSRunningApplication.current && app.bundleIdentifier != NSRunningApplication.current.bundleIdentifier {
                Task { @MainActor in
                    self?.lastActiveApp = app
                    print("[APP] Tracked last active app: \(app.localizedName ?? "unknown")")
                }
            }
        }

        statusBar.onPolishToggle { [weak self] enabled in
            self?.polishEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Self.polishDefaultsKey)
            if enabled {
                Task { [weak self] in
                    await self?.qwen?.preload()
                }
            }
        }

        statusBar.onSettings { [weak self] in
            self?.settings.showSettings()
        }

        settings.onEngineChanged = { [weak self] in
            Task { @MainActor in
                await self?.loadModel()
                if let qwen = self?.qwen {
                    await qwen.forceUnload()
                    if self?.polishEnabled == true {
                        await qwen.preload()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SottoIncomingCommand"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let text = notification.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                await self.handleIncomingCommandText(text)
            }
        }

        // Proactive suggestions from the EventBus (e.g. a download arrived → "unzip it?").
        // EventHandler posts these with a runnable "command"; route it through the same
        // pipeline so the bus's proactive commands actually execute instead of dead-ending.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SottoSuggestion"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let command = notification.userInfo?["command"] as? String, !command.isEmpty else { return }
            Task { @MainActor in
                print("[SUGGESTION] Running proactive command: \(command)")
                await self.handleIncomingCommandText(command)
            }
        }

        statusBar.onDictate { [weak self] in
            self?.beginRecording()
        }

        recorder.onSilenceDetected { [weak self] in
            Task { @MainActor in
                self?.endRecording()
            }
        }

        print("[SOTTO-APP] Creating QwenRefiner...")
        let refiner = QwenRefiner { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .notLoaded: self.statusBar.qwenStatus = "not loaded (loads on first use)"
                case .downloading(let pct): self.statusBar.qwenStatus = "loading… \(pct)%"
                case .ready: self.statusBar.qwenStatus = "ready"
                case .failed(let msg): self.statusBar.qwenStatus = "failed — \(msg)"
                }
            }
        }
        self.qwen = refiner

        if polishEnabled {
            Task {
                await refiner.preload()
            }
        }

        if #available(macOS 26.0, *) {
            self.coordinator = CoordinatorAgent()
            // Log the full live tool surface at launch so the log console shows what's available.
            let tools = JarvisToolbox.all().map { $0.name }.sorted()
            print("[TOOLS] \(tools.count) available: \(tools.joined(separator: ", "))")
            print("[TOOLS] MLX sub-agents: \(SettingsController.preferMLX ? "ON" : "OFF (using Apple Intelligence)")")
        }

        // Setup hands-free wake word detector
        if #available(macOS 10.15, *) {
            wakeDetector.onWakeWordDetected = { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    print("[WAKE] Wake word detected! Triggering Jarvis hands-free.")
                    self.currentMode = .jarvis
                    self.beginRecording()
                }
            }
        }

        // Resume any bulk background jobs left running from a previous launch.
        LongTaskEngine.resumePending()

        // Warm the on-device Apple Intelligence model so the first dictation/agent call
        // has no cold-start latency.
        JarvisAgent.prewarm()

        // ── Kernel event bus + proactive observers ──────────────────────────
        // Each observer runs as a sleeping background Task — 0 CPU until an event fires.
        // Combined RAM overhead: ~0 MB (pure Swift, no models loaded).
        EventHandler.start()          // routes bus events → HUD + voice
        Task {
            await MemoryCoordinator.shared.start() // learns user facts & vocabulary dynamically
        }
        ClipboardObserver.start()     // watches NSPasteboard every 1.5 s
        DownloadsObserver.start()     // FSEvents on ~/Downloads, kernel-level, 0 CPU idle
        BatteryObserver.start()       // IOKit, checks every 60 s
        CalendarProximityObserver.start() // EventKit, checks every 2 min
        NetworkObserver.start()       // NWPathMonitor, kernel callbacks, 0 CPU idle

        // Seed the CapabilityRegistry with all built-in tool descriptors, then bind the
        // kernel's reflex executors. The kernel uses the registry to route intents to the
        // cheapest capable path and runs reflex-tier ones directly (0 tokens).
        Task {
            await CapabilityRegistry.shared.seedBuiltins()
            let count = await CapabilityRegistry.shared.count()
            await Kernel.shared.seedReflexes()
            print("[KERNEL] CapabilityRegistry ready: \(count) capabilities indexed; reflexes bound.")
        }

        print("[SOTTO-APP] Creating HotkeyListener...")
        // Intuitive mapping: the dictation hotkey (⌘⇧K) does dictation; the Jarvis hotkey
        // (⌘⇧J) does Jarvis. Saying "Hey Jarvis …" also reroutes to Jarvis from either.
        let listener = HotkeyListener(
            onPress: { [weak self] in
                Task { @MainActor in
                    self?.currentMode = .dictation
                    self?.handleHotkeyPress()
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor in
                    self?.handleHotkeyRelease()
                }
            },
            onJarvisPress: { [weak self] in
                Task { @MainActor in
                    self?.currentMode = .jarvis
                    self?.handleHotkeyPress()
                }
            },
            onJarvisRelease: { [weak self] in
                Task { @MainActor in
                    self?.handleHotkeyRelease()
                }
            }
        )
        self.hotkey = listener
        listener.start()

        Task { @MainActor in
            await self.loadModel()
        }
    }

    /// Re-check permissions from Settings menu.
    func recheckPermissions() {
        Task { await PermissionCoordinator.shared.ensurePermissions() }
    }

    @MainActor
    func loadModel() async {
        state = .loadingModel
        print("[APP] loadModel() started: Preparing speech transcriber...")
        do {
            try await transcriber.prepare()
            state = .idle
            print("[APP] loadModel() succeeded: Speech model ready. App state is now IDLE.")
        } catch {
            state = .error("Model load failed: \(error.localizedDescription)")
            print("[APP] loadModel() failed: \(error.localizedDescription)")
        }
    }

    func beginRecording() {
        print("[APP] beginRecording() called. Current state: \(state)")

        if case .loadingModel = state {
            print("[APP] beginRecording() aborted: Speech model is loading")
            hud.show("⏳ Loading speech model…")
            NSSound(named: "Basso")?.play()
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                if case .loadingModel = self.state {
                    self.hud.hide()
                }
            }
            return
        }

        if case .transcribing = state {
            print("[APP] beginRecording() aborted: Currently transcribing")
            hud.show("⏳ Still transcribing…")
            NSSound(named: "Basso")?.play()
            return
        }

        if case .polishing = state {
            print("[APP] beginRecording() aborted: Currently polishing")
            hud.show("⏳ Still polishing…")
            NSSound(named: "Basso")?.play()
            return
        }

        if case .error(let msg) = state {
            if msg.contains("Model load") || msg.contains("Speech model is not loaded") {
                print("[APP] Retrying model load because hotkey was pressed in error state: \(msg)")
                hud.show("⏳ Retrying model load…")
                Task { @MainActor in
                    await loadModel()
                }
                return
            } else {
                print("[APP] Clearing transient error state '\(msg)' and starting recording")
                state = .idle
            }
        }

        guard case .idle = state else {
            print("[APP] beginRecording() aborted: State is not .idle (current: \(state))")
            return
        }

        // Capture the frontmost application at the start of recording
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost != NSRunningApplication.current,
           frontmost.bundleIdentifier != NSRunningApplication.current.bundleIdentifier {
            self.lastActiveApp = frontmost
            print("[APP] Captured frontmost application on recording start: \(frontmost.localizedName ?? "unknown")")
        }

        // Accessibility check to prevent silent key injection failures
        if !AXIsProcessTrusted() {
            print("[APP] beginRecording() aborted: AXIsProcessTrusted() returned false")
            hud.show("⚠️ Enable Accessibility in Settings")
            NSSound(named: "Basso")?.play()
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
                self.hud.hide()
            }
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            state = .error("Microphone access denied")
            scheduleErrorRecovery()
            return
        }

        do {
            self.recordingStart = Date()
            try recorder.start()
            state = .recording
            hud.show("●  Listening  [0:00 / 5:00]")
            NSSound(named: "Pop")?.play()

            // Start visualization timer
            self.visualizerTimer?.invalidate()
            self.visualizerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    guard case .recording = self.state else { return }
                    let rms = self.recorder.currentRMS
                    let bars = self.waveform(for: rms)
                    
                    let elapsed = Date().timeIntervalSince(self.recordingStart ?? Date())
                    let minutes = Int(elapsed) / 60
                    let seconds = Int(elapsed) % 60
                    let timeStr = String(format: "%d:%02d", minutes, seconds)
                    
                    self.hud.show("●  Listening  \(bars)  [\(timeStr) / 5:00]")
                }
            }

            // Auto-stop after 300 seconds (5 minutes safety timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    guard case .recording = self.state else { return }
                    self.endRecording()
                }
            }
        } catch {
            state = .error("Mic error: \(error.localizedDescription)")
            scheduleErrorRecovery()
        }
    }


    func endRecording() {
        guard case .recording = state else { return }
        visualizerTimer?.invalidate()
        visualizerTimer = nil

        let samples = recorder.stop()
        state = .transcribing
        hud.show("…  Transcribing")

        // Capture the focused app *now*, before transcription finishes.
        let context = ContextDetector.current()
        let mode = currentMode

        Task { @MainActor in
            // Ignore accidental taps shorter than ~0.3s of audio.
            guard samples.count > 4800 else {
                self.state = .idle
                self.hud.hide()
                return
            }
            do {
                var raw = try await self.transcriber.transcribe(samples)
                raw = VocabCorrector.apply(to: raw)
                print("[APP] Raw transcript (after vocab correction): '\(raw)' (mode: \(mode))")

                // A pending clarifying question takes this utterance as its answer, as a
                // follow-up turn — bypassing all normal routing.
                if self.pendingClarification {
                    self.pendingClarification = false
                    await self.continueClarification(answer: raw, samples: samples)
                    return
                }

                // The two hotkeys are fully independent — dictation is NEVER intercepted by
                // Jarvis, so they can't conflict. The "Hey Jarvis" wake prefix is only stripped
                // (optionally) when you're already in the Jarvis lane.
                switch mode {
                case .dictation:
                    await self.runDictationPipeline(raw: raw, samples: samples, context: context)
                case .jarvis:
                    let command = Self.jarvisWakeCommand(in: raw) ?? raw
                    await self.runJarvisPipeline(raw: command, samples: samples, context: context)
                }
            } catch {
                NSSound(named: "Basso")?.play()
                self.hud.hide()
                self.state = .error("Transcription failed: \(error.localizedDescription)")
                self.scheduleErrorRecovery()
            }
        }
    }

    private func handleHotkeyPress() {
        print("[APP] handleHotkeyPress() entered. Mode isPushToTalk: \(SettingsController.isPushToTalk)")
        if SettingsController.isPushToTalk {
            beginRecording()
        } else {
            // Toggle mode
            if case .recording = state {
                endRecording()
            } else {
                beginRecording()
            }
        }
    }

    private func handleHotkeyRelease() {
        print("[APP] handleHotkeyRelease() entered. Mode isPushToTalk: \(SettingsController.isPushToTalk)")
        if SettingsController.isPushToTalk {
            endRecording()
        }
    }

    private func waveform(for rms: Float) -> String {
        let levels = ["  ", "▂ ", "▂▃", "▂▃▅", "▂▃▅▆", "▂▃▅▆▇"]
        let index = min(Int(rms * 45.0), levels.count - 1)
        return levels[max(0, index)]
    }

    func updateWakeDetector() {
        if #available(macOS 10.15, *) {
            if case .idle = state, SettingsController.isHandsFreeEnabled {
                wakeDetector.start()
            } else {
                wakeDetector.stop()
            }
        }
    }
}

@MainActor final class ExplanationWindowController: NSObject {
    private var window: NSWindow?
    private var textView: NSTextView?
    
    func show(text: String, title: String) {
        if let window = self.window {
            window.close()
        }
        
        let width: CGFloat = 520
        let height: CGFloat = 420
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 15, left: 15, bottom: 15, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = NSColor.labelColor
        headerStack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(headerStack)
        
        let scrollView = NSTextView.scrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        let textView = scrollView.documentView as! NSTextView
        self.textView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.string = text
        textView.drawsBackground = false
        
        stack.addArrangedSubview(scrollView)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: -40)
        ])
        
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = window
    }
}

func hasRepetitiveLoops(_ text: String) -> Bool {
    let words = text.components(separatedBy: .whitespacesAndNewlines)
        .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        .filter { !$0.isEmpty }
    
    guard words.count >= 15 else { return false }
    
    var ngrams: [String: Int] = [:]
    for i in 0...(words.count - 5) {
        let ngram = words[i..<(i + 5)].joined(separator: " ")
        ngrams[ngram, default: 0] += 1
        if ngrams[ngram]! >= 3 {
            return true
        }
    }
    return false
}
