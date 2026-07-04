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
    // Preloaded sounds — avoids a per-play NSSound(named:) lookup on every keypress.
    let soundPop = NSSound(named: "Pop")
    let soundTink = NSSound(named: "Tink")
    let soundBasso = NSSound(named: "Basso")
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
    var coordinator: CoordinatorAgent?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    // Live streaming ASR state for the current press. The buffer continuation is created
    // synchronously in startRecording so the recorder tap never captures nil; partials are
    // DISPLAY-ONLY — they never route or execute anything (half-spoken text must not act).
    private var streamBufferContinuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private var streamingSetupTask: Task<Void, Never>?
    private var partialsTask: Task<Void, Never>?
    private var latestPartial: String = ""

    enum Mode {
        case dictation
        case jarvis
    }
    // Default to dictation (Sotto's original behavior). Each hotkey sets its own mode on
    // press, so dictation and Jarvis stay completely separate.
    var currentMode: Mode = .dictation
    // Set while Jarvis is waiting for the answer to a clarifying ("ASK:") question.
    var pendingClarification = false

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
            // Arm the watchdog only while in a transient state that can get stuck;
            // cancel it the instant we leave, eliminating the free-running 5s poll.
            switch state {
            case .transcribing: armWatchdog(limit: 20)
            case .polishing:    armWatchdog(limit: 45)
            default:
                watchdogTask?.cancel()
                watchdogTask = nil
            }
            if case .idle = state {
                Task { await EventBus.shared.emit(.idleReady) }
            }
        }
    }
    /// When the current `state` was entered. Drives the stuck-state watchdog so a
    /// transient state (`.transcribing` / `.polishing`) that never completes can't
    /// permanently wedge dictation — the app self-heals back to `.idle`.
    private var stateEnteredAt = Date()
    private var watchdogTask: Task<Void, Never>?

    init() {
        // Dictation ships with LLM polish ON by default — the primary experience is
        // clean polished output, not raw ASR. Polish runs on the shared Apple
        // Intelligence model (same base model Siri uses, so no extra ~2 GB), kept warm
        // because dictation is the daily driver. Toggle off via the status-bar menu.
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

        // The SHARED instance, deliberately: the memory-pressure handler and
        // MicrotaskQueue both target CoordinatorAgent.shared — a private instance here
        // would keep its warm session invisible to (and safe from) pressure eviction.
        self.coordinator = CoordinatorAgent.shared
        let tools = JarvisToolbox.all().map { $0.name }.sorted()
        print("[TOOLS] \(tools.count) available: \(tools.joined(separator: ", "))")
        // Run availability diagnostics at startup to surface clear log output
        // instead of silent failures later.
        JarvisDiagnostics.reportAvailability()

        // Setup hands-free wake word detector
        wakeDetector.onWakeWordDetected = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                print("[WAKE] Wake word detected! Triggering Jarvis hands-free.")
                self.currentMode = .jarvis
                self.beginRecording()
            }
        }

        // Resume any bulk background jobs left running from a previous launch.
        LongTaskEngine.resumePending()

        // Dictation is the daily driver, so ONLY its polish session is warmed at launch
        // (via intelligence.preload() in loadModel). Jarvis is used a few times a day, so it
        // stays LAZY — its classifier/coordinator model loads on first Jarvis press, not now.
        // Prewarming a second Apple Intelligence session here competes with polish for unified
        // memory on 8 GB and was tipping launch into CriticalMemoryPressure.
        // CoordinatorAgent.prewarm() only bootstraps the CommandLearner hint cache (no model).
        CoordinatorAgent.prewarm()

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
        setupMemoryPressureObserver()

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
            soundBasso?.play()
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
            soundBasso?.play()
            return
        }

        if case .polishing = state {
            print("[APP] beginRecording() aborted: Currently polishing")
            hud.show("⏳ Still polishing…")
            soundBasso?.play()
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
            self.latestPartial = ""

            // Show current memory status on the HUD (no-op unless the debug setting is on).
            self.updateMemoryLedger()

            // Live streaming ASR. The buffer stream is created SYNCHRONOUSLY so the
            // recorder tap holds a real continuation from the very first frame —
            // AsyncStream buffers until the backend starts consuming. The session comes
            // up in the background; endRecording AWAITS streamingSetupTask before
            // finishStreaming(), so a session can never appear mid-batch-transcription.
            let (bufferStream, bufferContinuation) = AsyncStream<SendableAudioBuffer>.makeStream()
            self.streamBufferContinuation = bufferContinuation
            self.streamingSetupTask = Task { @MainActor in
                do {
                    guard let partials = try await self.transcriber.startStreaming(feeding: bufferStream) else {
                        // Backend can't stream (legacy fallback). Finish the buffer stream so
                        // the recorder tap stops piling AVAudioPCMBuffers into an unbounded,
                        // unconsumed AsyncStream for the whole recording — a real memory cost
                        // on the 8 GB target since recorder.samples already holds the audio.
                        self.streamBufferContinuation?.finish()
                        self.streamBufferContinuation = nil
                        return
                    }
                    // Recording may have ended while the session came up — the session
                    // stays registered and endRecording's finishStreaming() consumes it;
                    // we only skip the (now pointless) HUD partials loop.
                    guard case .recording = self.state else { return }
                    self.partialsTask = Task { @MainActor in
                        for await partial in partials { self.latestPartial = partial }
                    }
                } catch {
                    // Same reasoning: don't leave the tap feeding an unconsumed stream.
                    self.streamBufferContinuation?.finish()
                    self.streamBufferContinuation = nil
                    print("[APP] Streaming ASR unavailable for this press: \(error.localizedDescription)")
                }
            }

            try recorder.start(onBuffer: { bufferContinuation.yield($0) })
            state = .recording
            hud.show("●  Listening  [0:00 / 5:00]")
            soundPop?.play()

            // Prewarm ASR on the MainActor while the user is speaking.
            // MainActor isolation is critical: running ASR initialization on a background cooperative thread
            // causes SFUtilities.defaultClientID to fail its internal dispatch_assert_queue(dispatch_get_main_queue()) assertion and crash.
            // Deliberately no LanguageModelSession().prewarm() here: the polish session is already
            // warm in SottoIntelligence, and a throwaway per-press prewarm forces the ~2 GB base
            // model resident on every keypress — a direct CriticalMemoryPressure trigger on 8 GB.
            Task(priority: .userInitiated) { @MainActor in
                try? await self.transcriber.prepare()
            }

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
                    // Live transcript preview from the streaming ASR partials — display
                    // only; routing always waits for the final key-release transcript.
                    let preview = self.latestPartial.isEmpty
                        ? ""
                        : "  “…\(String(self.latestPartial.suffix(42)))”"
                    self.hud.show("●  Listening  \(bars)  [\(timeStr) / 5:00]\(preview)")
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

        // End the audio input and stop the partial preview — on every exit path.
        streamBufferContinuation?.finish()
        streamBufferContinuation = nil
        partialsTask?.cancel()
        partialsTask = nil
        latestPartial = ""
        let setupTask = streamingSetupTask
        streamingSetupTask = nil

        // Ignore accidental taps shorter than ~0.3s of audio — check synchronously
        // before transitioning state so we don't flash the "Transcribing" HUD.
        guard samples.count > 4800 else {
            // The streaming session (if it came up) is left registered: the next
            // startStreaming()/transcribe() tears it down on the actor, which avoids
            // racing a cancel against a rapid next press.
            state = .idle
            hud.showResult("Hold ⌘⇧K while speaking, then release", autoHideAfter: 2.0)
            return
        }

        state = .transcribing
        hud.show("…  Transcribing")

        // Capture the focused app now, before transcription finishes.
        // currentCached() is zero-cost between app switches.
        let context = ContextDetector.currentCached()
        let mode = currentMode

        Task { @MainActor in
            do {
                // Settle the streaming session first: after this await it is either
                // registered (finishStreaming consumes it) or failed (nil → batch). It
                // costs nothing extra — a slow prepare() would stall batch ASR equally.
                await setupTask?.value

                // Prefer the streaming transcript: the audio was analyzed live while the
                // user spoke, so this skips a second full ASR pass over the same speech.
                var raw: String
                if let streamed = await self.transcriber.finishStreaming() {
                    print("[APP] Streaming transcript used (\(streamed.count) chars); batch ASR skipped.")
                    raw = streamed
                } else {
                    raw = try await self.transcriber.transcribe(samples)
                }
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
                soundBasso?.play()
                self.hud.hide()
                self.state = .error("Transcription failed: \(error.localizedDescription)")
                self.scheduleErrorRecovery()
            }
        }
    }

    func updateMemoryLedger() {
        // Debug instrumentation only — end users shouldn't see session bookkeeping.
        guard SettingsController.showMemoryLedger else {
            hud.setMemoryLedger("")
            return
        }
        Task { @MainActor in
            let state = await MemoryLedger.shared.fetchState()
            var active: [String] = []
            if state.polishWarm { active.append("polish") }
            if state.coordinatorWarm { active.append("coord") }
            if state.osControlWarm { active.append("os") }
            if state.webResearcherWarm { active.append("research") }
            if state.scriptingWarm { active.append("script") }
            
            let activeStr = active.isEmpty ? "none" : active.joined(separator: ",")
            let ledgerText = "Warm: [\(activeStr)] | Evict: \(state.evictions)"
            hud.setMemoryLedger(ledgerText)
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

    private func armWatchdog(limit: TimeInterval) {
        watchdogTask?.cancel()
        let enteredAt = stateEnteredAt
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled else { return }
            let stuckFor = Date().timeIntervalSince(enteredAt)
            print("[WATCHDOG] State \(self.state) stuck for \(Int(stuckFor))s (limit \(Int(limit))s); force-resetting to idle.")
            self.hud.hide()
            self.state = .idle
            self.soundBasso?.play()
        }
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

    private func setupMemoryPressureObserver() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            print("[SYSTEM-MEMORY] OS warned of memory pressure: \(event)")
            Task {
                await OSControlAgent.shared.unload()
                await WebResearcherAgent.shared.unload()
                await ScriptingExecutorAgent.shared.unload()
                await CoordinatorAgent.shared.unload()
                if let intel = self?.intelligence {
                    if event.contains(.critical) {
                        await intel.forceUnload()
                    }
                }
            }
        }
        source.resume()
        self.memoryPressureSource = source
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
        
        let tools = JarvisToolbox.all()
        for (idx, tool) in tools.enumerated() {
            text += "\(idx + 1). \(tool.name)\n"
            text += "   Description: \(tool.description)\n\n"
        }
        
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
