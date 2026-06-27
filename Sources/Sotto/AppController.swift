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
    var intelligence: SottoIntelligence?
    var polishEnabled: Bool
    let wakeDetector = WakeWordDetector()
    var visualizerTimer: Timer?
    var recordingStart: Date?
    var recentTranscripts: [String] = []
    var lastActiveApp: NSRunningApplication?
    var appActivity: NSObjectProtocol?
    var coordinator: AnyObject?
    private var recordingTimeoutTask: Task<Void, Never>?

    enum Mode {
        case dictation
        case jarvis
    }
    // Default to dictation (Sotto's original behavior). Each hotkey sets its own mode on
    // press, so dictation and Jarvis stay completely separate.
    var currentMode: Mode = .dictation
    // Set while Jarvis is waiting for the answer to a clarifying ("ASK:") question.
    var pendingClarification = false

    var intelligenceEngine: SottoIntelligence? { intelligence }

    func showHUD(_ text: String) {
        hud.show(text)
    }

    func hideHUD() {
        hud.hide()
    }

    var state: State = .loadingModel {
        didSet {
            stateEnteredAt = Date()
            statusBar.update(for: state)
            updateWakeDetector()
            if case .idle = state {
                Task { await EventBus.shared.emit(.idleReady) }
            }
        }
    }
    /// When the current `state` was entered. Drives the stuck-state watchdog so a
    /// transient state (`.transcribing` / `.polishing`) that never completes can't
    /// permanently wedge dictation — the app self-heals back to `.idle`.
    private var stateEnteredAt = Date()
    private var watchdogTimer: Timer?

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

    /// Nothing external to tear down — the brain (Apple Foundation Models)
    /// and TTS (AVSpeechSynthesizer) all run inside this process.
    func cleanup() {}

    func start() {
        print("[SOTTO-APP] AppController.start() called")
        CommandEngine.registerAllEnabledSkills()

        // Prevent App Nap: Keep Sotto awake and responsive to global hotkeys and audio recording
        // .latencyCritical keeps the event-delivery path hot so hotkeys fire instantly,
        // without preventing system idle sleep — the previous .idleSystemSleepDisabled
        // kept the entire Mac awake 24/7 even when idle, burning significant battery.
        self.appActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Sotto must respond instantly to global hotkeys and voice recording."
        )

        // Stuck-state watchdog: if a transient state never completes (e.g. a speech
        // engine that never returns, or a polish that hangs past its own timeout),
        // force the app back to `.idle` so the next hotkey press works instead of
        // showing "Still transcribing…" forever. Recording is intentionally exempt —
        // push-to-talk may legitimately run long and already has its own 300s cap.
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                let stuckFor = Date().timeIntervalSince(self.stateEnteredAt)
                let limit: TimeInterval
                switch self.state {
                case .transcribing: limit = 20   // transcribe has an 8s internal timeout
                case .polishing:    limit = 45   // increased from 25 to allow for cold-start model load or complex tool loops
                default:            return
                }
                if stuckFor > limit {
                    print("[WATCHDOG] State \(self.state) stuck for \(Int(stuckFor))s (limit \(Int(limit))s); force-resetting to idle.")
                    self.hud.hide()
                    self.state = .idle
                    NSSound(named: "Basso")?.play()
                }
            }
        }

        // Cache app context so ContextDetector.currentCached() is zero-cost between app switches.
        ContextDetector.startObservingAppSwitches()

        statusBar.update(for: state)
        Task { await PermissionCoordinator.shared.ensurePermissions() }
        PermissionWatcher.shared.start()    // live-monitors all permissions, auto-restarts on AX grant

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
                    await self?.intelligence?.preload()
                }
            }
        }

        statusBar.onSettings { [weak self] in
            self?.settings.showSettings()
        }

        settings.onEngineChanged = { [weak self] in
            Task { @MainActor in
                await self?.loadModel()
                if let intel = self?.intelligence {
                    await intel.forceUnload()
                    if self?.polishEnabled == true {
                        await intel.preload()
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

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SottoOpenGuide"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.showJarvisGuide()
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

        print("[SOTTO-APP] Creating SottoIntelligence (Apple Foundation Models)...")
        let intel = SottoIntelligence { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .notLoaded: self.statusBar.intelligenceStatus = "not loaded"
                case .downloading(let pct): self.statusBar.intelligenceStatus = "loading… \(pct)%"
                case .ready: self.statusBar.intelligenceStatus = "ready"
                case .failed(let msg): self.statusBar.intelligenceStatus = "unavailable — \(msg)"
                }
            }
        }
        self.intelligence = intel

        if polishEnabled {
            Task {
                await intel.preload()
            }
        }

        if #available(macOS 26.0, *) {
            self.coordinator = CoordinatorAgent()
            let tools = JarvisToolbox.all().map { $0.name }.sorted()
            print("[TOOLS] \(tools.count) available: \(tools.joined(separator: ", "))")
            // Run availability diagnostics at startup to surface clear log output
            // instead of silent failures later.
            JarvisDiagnostics.reportAvailability()
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

        // Warm both Apple Intelligence sessions at launch:
        //   JarvisAgent  — intent classifier + single-hop tool calls
        //   CoordinatorAgent — multi-turn Jarvis orchestration (was cold before, now warm)
        JarvisAgent.prewarm()
        if #available(macOS 26.0, *) { CoordinatorAgent.prewarm() }

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
        GitObserver.start()           // polls git repos every 5 min for changes/conflicts
        Task { await MicrotaskQueue.shared.start() }  // background task queue, drains on idle

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

        // Show a brief startup HUD so the user always knows Sotto launched and
        // can see where the HUD lives — even when the menu bar icon is hidden by overflow.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            self.hud.showResult("✦ Sotto is running  •  ⌘⇧K to dictate", autoHideAfter: 3.5)
            
            // Show onboarding guide automatically on first launch
            let hasShown = UserDefaults.standard.bool(forKey: "sotto_hasShownOnboarding")
            if !hasShown {
                try? await Task.sleep(for: .seconds(1))
                self.showJarvisGuide()
                UserDefaults.standard.set(true, forKey: "sotto_hasShownOnboarding")
            }
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
                try? await Task.sleep(for: .seconds(2)) // 2 seconds
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

        // Warn about Accessibility but don't block — hotkeys already work,
        // and TextInjector has its own fallback. Hard-blocking here was causing
        // "Accessibility granted but still refused" after the user enables it.
        if !AXIsProcessTrusted() {
            print("[APP] ⚠️ Accessibility not yet trusted — proceeding anyway (text injection may fall back to clipboard)")
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

            // Waveform at 15fps (66ms). Skip silent frames — saves ~65% of main-thread
            // wakeups during the typical mostly-silent recording session.
            self.visualizerTimer?.invalidate()
            self.visualizerTimer = Timer.scheduledTimer(withTimeInterval: 0.066, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    guard case .recording = self.state else { return }
                    let rms = self.recorder.currentRMS
                    guard rms > 0.005 else { return }
                    let bars = self.waveform(for: rms)
                    let elapsed = Date().timeIntervalSince(self.recordingStart ?? Date())
                    let timeStr = String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
                    self.hud.show("●  Listening  \(bars)  [\(timeStr) / 5:00]")
                }
            }

            // Cancellable 5-minute auto-stop — endRecording() cancels this immediately
            // so there is never a phantom-firing GCD timer from a prior recording session.
            recordingTimeoutTask?.cancel()
            recordingTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard let self, case .recording = self.state else { return }
                self.endRecording()
            }
        } catch {
            state = .error("Mic error: \(error.localizedDescription)")
            scheduleErrorRecovery()
        }
    }


    func endRecording() {
        guard case .recording = state else { return }
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
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
        
        guard let textView = scrollView.documentView as? NSTextView else { return }
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

// MARK: - Jarvis Help & Guide Onboarding Extension
extension AppController {
    @MainActor func showJarvisGuide() {
        let guideText = AppController.generateJarvisGuideText()
        explanationController.show(text: guideText, title: "Jarvis Help & Guide")
    }

    static func generateJarvisGuideText() -> String {
        var text = """
        ==================================================
                      SOTTO / JARVIS SYSTEM GUIDE
        ==================================================
        
        Welcome to Sotto, your privacy-first, fully offline on-device AI assistant for Mac!
        
        Sotto operates in two modes:
        1. Dictation Mode (⌘⇧K / PTT):
           Polishes your speech (fixing grammar/filler words) and inserts it directly into the active app.
           
        2. Jarvis Mode (⌘⇧J / PTT):
           Your offline AI tool-calling assistant. It understands your intent, automatically chooses the right tools, and executes commands locally.
           
        --------------------------------------------------
        HOW TO USE
        --------------------------------------------------
        - Push-To-Talk: Press and hold ⌘⇧J (Jarvis) or ⌘⇧K (Dictation). Speak while holding, then release to execute.
        - Tap-To-Talk: Toggle in Settings. Tap once to start listening, and Sotto will automatically stop when you are silent.
        - Wake Word: If enabled in Settings, say "Hey Jarvis" hands-free!
        
        --------------------------------------------------
        POPULAR COMMAND EXAMPLES
        --------------------------------------------------
        Try speaking these commands in Jarvis Mode to test the system:
        
        - "what is the weather like in Berlin today?"
        - "open Spotify and play some jazz music"
        - "turn the volume down to twenty percent"
        - "open Safari to apple.com"
        - "search Wikipedia for quantum computing details"
        - "read what is currently on the screen"
        - "find files larger than 100 megabytes in my home folder"
        - "explain why this compiler error about actor isolation occurs"
        
        --------------------------------------------------
        AVAILABLE NATIVE TOOLS FOR JARVIS
        --------------------------------------------------
        Here are the tools currently configured and ready for Jarvis:
        
        """
        
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let tools = JarvisToolbox.all()
            for (idx, tool) in tools.enumerated() {
                text += "\(idx + 1). \(tool.name)\n"
                text += "   Description: \(tool.description)\n\n"
            }
        } else {
            text += "Native Apple Foundation Model tools require macOS 26.0 or later.\n"
        }
        #else
        text += "Native Apple Foundation Model tools require macOS 26.0 or later.\n"
        #endif
        
        text += """
        --------------------------------------------------
        TIPS FOR TESTING & DEVELOPING
        --------------------------------------------------
        - Logs: View real-time logs using the "Show Console" menu item.
        - Custom Vocab: Add custom jargon and acronyms under Settings. Sotto will automatically learn them to improve transcription spelling!
        """
        return text
    }
}
