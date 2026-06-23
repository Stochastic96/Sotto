import AppKit
import AVFoundation
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

    private let statusBar: StatusBarController
    private let hud = HUDOverlay()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let injector = TextInjector()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var activeSound: NSSound?
    private let settings = SettingsController()
    private let explanationController = ExplanationWindowController()
    private let promptReview = PromptReviewWindowController()
    private var hotkey: HotkeyListener?
    private var qwen: QwenRefiner?
    private var polishEnabled: Bool
    private let wakeDetector = WakeWordDetector()
    private var visualizerTimer: Timer?
    private var recordingStart: Date?
    private var recentTranscripts: [String] = []
    private var lastActiveApp: NSRunningApplication?
    private var appActivity: NSObjectProtocol?
    private var coordinator: AnyObject?

    enum Mode {
        case dictation
        case jarvis
    }
    // Default to dictation (Sotto's original behavior). Each hotkey sets its own mode on
    // press, so dictation and Jarvis stay completely separate.
    private var currentMode: Mode = .dictation
    // Set while Jarvis is waiting for the answer to a clarifying ("ASK:") question.
    private var pendingClarification = false

    var qwenRefiner: QwenRefiner? {
        return qwen
    }

    func showHUD(_ text: String) {
        hud.show(text)
    }

    func hideHUD() {
        hud.hide()
    }

    private(set) var state: State = .loadingModel {
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
            for term in storedVocab where !Self.commonWordStopList.contains(term.lowercased()) {
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
        requestPermissions()

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

    private func requestPermissions() {
        // Microphone — triggers the system prompt on first run.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                print("[SOTTO] Sotto: microphone access denied — dictation cannot work without it.")
            }
        }
        // Accessibility — needed for the global hotkey tap and synthetic ⌘V.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            print("[SOTTO] Sotto: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility).")
        }
        // Screen Recording — needed for Screen OCR.
        if #available(macOS 10.15, *) {
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
                print("[SOTTO] Sotto: waiting for Screen Recording permission (System Settings → Privacy & Security → Screen Recording).")
            }
        }
    }

    @MainActor
    private func loadModel() async {
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

    private func beginRecording() {
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


    private func endRecording() {
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
                let raw = try await self.transcriber.transcribe(samples)
                print("[APP] Raw transcript: '\(raw)' (mode: \(mode))")

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

    // MARK: - Dictation pipeline (⌘⇧K) — PURE dictation: listen → AI polish → paste.
    //         No commands, no tasks, no Jarvis. Those live only in the Jarvis pipeline.

    private func runDictationPipeline(raw: String, samples: [Float], context: AppContext) async {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var polishDuration = 0.0

        guard !text.isEmpty else {
            state = .idle
            hud.hide()
            return
        }

        // Skip polish for short inputs — saves 2-3 seconds on quick commands
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let skipPolish = wordCount < 6 || text.count < 40

        // AI polish (Apple Intelligence, warm) with a 15s safety timeout + sanity checks.
        if polishEnabled && !skipPolish, let qwen = self.qwen {
            state = .polishing
            hud.show("✨  Polishing…")
            let polishStart = CFAbsoluteTimeGetCurrent()
            do {
                let polished = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await qwen.refine(text, context: context, history: self.recentTranscripts) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw NSError(domain: "SottoQwen", code: -1, userInfo: [NSLocalizedDescriptionKey: "AI Polish timed out"])
                    }
                    guard let result = try await group.next() else {
                        throw NSError(domain: "SottoQwen", code: -2, userInfo: [NSLocalizedDescriptionKey: "No result returned"])
                    }
                    group.cancelAll()
                    return result
                }
                if isAcceptablePolish(original: text, polished: polished) {
                    text = polished
                }
            } catch {
                print("[DICTATION] AI Polish failed/timed out: \(error.localizedDescription). Using raw text.")
            }
            polishDuration = CFAbsoluteTimeGetCurrent() - polishStart
        }

        NSSound(named: "Tink")?.play()

        // Reactivate the target app and paste. No search shortcuts, no files, no commands.
        if let app = self.lastActiveApp {
            if #available(macOS 14.0, *) { NSApplication.shared.yieldActivation(to: app) }
            app.activate(options: [])
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        await injector.inject(text, fileURL: nil, targetPID: lastActiveApp?.processIdentifier)

        statusBar.lastTranscript = text
        recentTranscripts.append(text)
        if recentTranscripts.count > 5 { recentTranscripts.removeFirst() }
        CommandEngine.lastResult = text
        learnFromDictation(raw: raw, polished: text)
        DatasetLogger.shared.log(mode: "dictation", app: lastActiveApp?.localizedName, rawTranscript: raw, response: text, kind: "polish", samples: samples)

        let total = CFAbsoluteTimeGetCurrent() - pipelineStart
        print("[BENCHMARK] Dictation \(String(format: "%.0f", total * 1000))ms (polish: \(String(format: "%.0f", polishDuration * 1000))ms)")
        hud.show("✓ Done (\(String(format: "%.1f", total))s)")
        state = .idle
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); hud.hide() }
    }

    /// Sanity-checks an AI-polished dictation against truncation / expansion / loops.
    private func isAcceptablePolish(original: String, polished: String) -> Bool {
        if polished.isEmpty { return false }
        let originalWords = original.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let polishedWords = polished.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if (polishedWords.count < originalWords.count / 3) || (originalWords.count >= 8 && polishedWords.count <= 2) {
            print("[DICTATION] Polish truncated; using raw."); return false
        }
        if (Double(polishedWords.count) > Double(originalWords.count) * 2.5) && originalWords.count >= 6 {
            print("[DICTATION] Polish expanded (likely hallucination); using raw."); return false
        }
        if hasRepetitiveLoops(polished) {
            print("[DICTATION] Polish looped; using raw."); return false
        }
        // Content-overlap guard: a weak model can echo a few-shot example or a prior
        // dictation instead of polishing the current input. Such output passes the
        // length checks (similar word count) but shares almost no words with the raw
        // transcript. Require meaningful overlap, else fall back to raw.
        let origSet = Set(originalWords.map { $0.lowercased() }.filter { $0.count > 3 })
        let polSet = Set(polishedWords.map { $0.lowercased() }.filter { $0.count > 3 })
        if originalWords.count >= 5, !origSet.isEmpty {
            let overlap = Double(origSet.intersection(polSet).count) / Double(origSet.count)
            if overlap < 0.2 {
                print("[DICTATION] Polish unrelated to input (overlap \(String(format: "%.0f%%", overlap * 100))); using raw.")
                return false
            }
        }
        return true
    }

    /// If the utterance is a weather ask, returns the city to look up (named city, or the
    /// saved home city). Lets us answer weather deterministically instead of trusting the
    /// small model, which sometimes hallucinates a "permission denied" for a keyless API.
    private static func weatherCity(in raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.contains("weather") || lower.contains("temperature") || lower.contains("forecast") else { return nil }
        let stop = ["today", "right now", "now", "please", "currently", "tomorrow", "outside", "like"]
        for marker in ["weather in ", "weather for ", "weather at ", "temperature in ", "forecast for ", "forecast in "] {
            if let r = lower.range(of: marker) {
                var city = String(lower[r.upperBound...])
                for w in stop { city = city.replacingOccurrences(of: w, with: "") }
                city = city.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
                if !city.isEmpty { return city }
            }
        }
        let home = UserDefaults.standard.string(forKey: "sotto_home_city") ?? ""
        return home.isEmpty ? nil : home
    }

    /// If the utterance explicitly asks to route to Siri/Apple Intelligence, returns the
    /// "Siri-like" words including the on-device transcriber's frequent mishears of "Siri".
    private static let siriWords: Set<String> = [
        "siri", "siris", "siddhi", "sidi", "sidhi", "suri", "sirhi", "sierra",
        "cyrus", "city", "syria", "seedy", "cd", "sidney", "sitty", "sirius", "cidi",
    ]
    private static let siriVerbs: Set<String> = ["ask", "asks", "tell", "open", "launch", "start", "hey", "type"]
    /// Verbs that, when they follow "open <word> and …", signal a Siri request — they're
    /// question words and direct-address forms that you'd only say to an assistant, never
    /// to an app. Kept narrow on purpose: "find", "search", "show", "check", "get", "set"
    /// are all legitimate Jarvis commands and must not be hijacked here.
    private static let siriFollowVerbs: Set<String> = [
        "ask", "asks", "tell",
        "what", "whats", "who", "whos", "when", "how", "why", "where",
    ]

    /// Detects an explicit "ask/open Siri …" command anywhere in the utterance — robust to
    /// the garbled wake word ("Hejarvis") and Siri mishears. Returns the prompt to forward,
    /// "" when it's an open-only command, or nil when it isn't a Siri command at all.
    /// (Lowercased; Siri doesn't care about casing.)
    private static func siriPrompt(in raw: String) -> String? {
        let words = raw.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?")) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        // Pass 1: an explicit verb followed by a (possibly misheard) Siri word.
        for i in words.indices where siriVerbs.contains(words[i]) || words[i].hasSuffix("jarvis") {
            var j = i + 1
            if j < words.count, words[j] == "to" || words[j] == "the" { j += 1 }
            guard j < words.count, siriWords.contains(words[j]) else { continue }
            // Skip connective words so the prompt starts cleanly ("open siri and ask X" → "X").
            var k = j + 1
            while k < words.count, ["to", "and", "ask", "asks", "please", "for"].contains(words[k]) { k += 1 }
            return words[k...].joined(separator: " ")
        }

        // Pass 2: "open <ANY word> and <ask/check/what/who…> …" — catches every future ASR
        // mishear of "Siri" without naming it, because you don't say "open Chrome and ask…".
        for i in words.indices where ["open", "launch", "start"].contains(words[i]) {
            let andIdx = i + 2
            guard andIdx + 1 < words.count, words[andIdx] == "and",
                  siriFollowVerbs.contains(words[andIdx + 1]) else { continue }
            var k = andIdx + 1
            while k < words.count, ["ask", "asks", "to", "please"].contains(words[k]) { k += 1 }
            return words[k...].joined(separator: " ")
        }
        return nil
    }

    /// Strip chat-template role tokens the on-device model sometimes leaks (e.g. a leading
    /// "model\n" or "assistant ") so they never reach the screen or the voice.
    private static func sanitizeReply(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for junk in ["model\n", "model ", "assistant\n", "assistant ", "<|assistant|>"] {
            if r.lowercased().hasPrefix(junk) {
                r = String(r.dropFirst(junk.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return r == "model" || r == "assistant" ? "" : r
    }

    /// One spoken line for a result: the headline clause only. The glass HUD card carries
    /// the full detail, so Jarvis says a quick line instead of reading everything aloud.
    private func shortSpoken(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let clause = firstLine.split(separator: ",", maxSplits: 1).first.map(String.init) ?? firstLine
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 70 ? trimmed : String(trimmed.prefix(70))
    }

    /// If the utterance opens with the "Hey Jarvis" wake phrase (robust to the ASR mishearing
    /// it as one garbled word, e.g. "Hejarvis"), returns the command with the wake words
    /// stripped; otherwise nil. Lets the user summon Jarvis from any mode.
    private static func jarvisWakeCommand(in raw: String) -> String? {
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        func isWake(_ w: String) -> Bool {
            let t = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            return t == "jarvis" || t.hasSuffix("jarvis")   // also catches "hejarvis"
        }
        var dropCount = 0
        if words[0].lowercased() == "hey", words.count > 1, isWake(words[1]) {
            dropCount = 2
        } else if isWake(words[0]) {
            dropCount = 1
        }
        guard dropCount > 0 else { return nil }
        let rest = words.dropFirst(dropCount).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Presents a Jarvis reply: when the model asks a clarifying question (the `ASK:`
    /// convention), speak it and re-open the mic for the answer; otherwise show + speak the
    /// reply normally. Manages `state`/HUD lifecycle.
    @MainActor
    private func presentJarvisReply(_ reply: String, raw: String) {
        if reply.hasPrefix(kClarificationPrefix) {
            let question = String(reply.dropFirst(kClarificationPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            print("[JARVIS] Clarifying question: \(question)")
            hud.show("❓ \(question)")
            speak(question)
            pendingClarification = true
            state = .idle
            // Re-open the mic for the answer once the question has been spoken.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.pendingClarification, case .idle = self.state else { return }
                self.beginRecording()
            }
            return
        }
        if reply.isEmpty {
            hud.showResult(Quips.done())
        } else {
            // Full reply in the glass card; speak only the one-line headline.
            CommandEngine.lastResult = reply
            hud.showResult(reply)
            speak(shortSpoken(reply))
        }
        state = .idle
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.hud.hide() }
    }

    /// Continues the Jarvis session with the user's answer to a clarifying question, reusing
    /// the same multi-turn transcript so prior context is preserved.
    private func continueClarification(answer: String, samples: [Float]) async {
        guard #available(macOS 26.0, *), let coord = self.coordinator as? CoordinatorAgent else {
            state = .idle; hud.hide(); return
        }
        state = .polishing
        hud.show("✨  Jarvis…")
        do {
            let reply = Self.sanitizeReply(try await coord.handleTurn(userInput: answer, isFollowUp: true))
            print("[JARVIS] Clarification reply: '\(reply)'")
            DatasetLogger.shared.log(mode: "jarvis-clarify", app: lastActiveApp?.localizedName, rawTranscript: answer, response: reply, kind: "agent", samples: samples)
            TaskJournal.record(command: answer, reply: reply)
            presentJarvisReply(reply, raw: answer)
        } catch {
            print("[JARVIS] Clarification failed: \(error.localizedDescription)")
            hud.show("⚠️ Jarvis Error")
            speak("Jarvis is unavailable.")
            state = .idle
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); self.hud.hide() }
        }
    }

    /// Entry point for App Intents / Shortcuts / Siri: run a request through the Jarvis brain
    /// (the Coordinator's fast Apple-Intelligence lane) and return the spoken reply. Stays off
    /// the mic/HUD recording flow so it's snappy and headless.
    @MainActor
    func runJarvisRequest(_ text: String) async -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "What would you like me to do?" }
        print("[INTENT] Jarvis request (App Intents/Shortcuts): '\(clean)'")
        if #available(macOS 26.0, *), let coord = self.coordinator as? CoordinatorAgent {
            do {
                let reply = Self.sanitizeReply(try await coord.handleTurn(userInput: clean))
                DatasetLogger.shared.log(mode: "jarvis-intent", app: nil, rawTranscript: clean, response: reply, kind: "agent", samples: nil)
                TaskJournal.record(command: clean, reply: reply)
                return reply.isEmpty ? "Done." : reply
            } catch {
                return "Jarvis couldn't do that: \(error.localizedDescription)"
            }
        }
        return "Jarvis needs Apple Intelligence, which isn't available on this Mac."
    }

    // MARK: - Jarvis pipeline (⌘⇧J) — full OS assistant: skills, native actions, agent, orchestrator.

    /// Records which lane handled a command and how long (transcript-ready → action)
    /// it took, then logs a one-liner. The latency excludes recording/transcription so
    /// it isolates the lane's own "thinking" cost — the number to compare against Siri.
    private func finishLane(_ lane: Lane, start: CFAbsoluteTime, raw: String) {
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[LANE] \(lane.rawValue) \(String(format: "%.0f", ms))ms — '\(raw.prefix(48))'")
        Task { await LaneStats.shared.record(lane: lane, ms: ms) }
    }

    private func runJarvisPipeline(raw: String, samples: [Float], context: AppContext) async {
        let laneStart = CFAbsoluteTimeGetCurrent()

        // "lane stats" / "jarvis stats" — show the measured three-lane distribution.
        let lowerRaw = raw.lowercased()
        if lowerRaw.contains("lane stats") || lowerRaw.contains("jarvis stats") || lowerRaw.contains("performance stats") {
            let summary = await LaneStats.shared.summary()
            explanationController.show(text: summary, title: "Jarvis Lane Stats")
            hud.show("📊 Lane stats")
            state = .idle
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); hud.hide() }
            return
        }

        // 0. "ask/open Siri …" wins FIRST — no tool routing, no model, no other scripts.
        // Just open the Siri box and (if there's a prompt) paste it. Fastest possible path.
        if let siriAsk = Self.siriPrompt(in: raw) {
            if siriAsk.isEmpty {
                hud.show("􀊫  Opening Siri…")
                await SiriBridge.openOnly()
                hud.showResult("Siri's up. " + Quips.siri())
            } else {
                hud.show("􀊫  Asking Siri…")
                await SiriBridge.send(siriAsk)
                let quip = Quips.siri()
                hud.showResult("\(quip)\n› \(siriAsk)")
                speak(quip)
            }
            print("[JARVIS] Siri path (prompt: '\(siriAsk)')")
            TaskJournal.record(command: raw, reply: "Siri: \(siriAsk.isEmpty ? "(opened)" : siriAsk)")
            finishLane(.reflex, start: laneStart, raw: raw)
            state = .idle
            Task { try? await Task.sleep(nanoseconds: 2_500_000_000); hud.hide() }
            return
        }

        // 1. User-only skill approval gate (the only way a drafted skill becomes runnable).
        let lowerApproval = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["enable skill ", "approve skill ", "activate skill "] {
            if lowerApproval.hasPrefix(prefix) {
                var skillName = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(prefix.count))
                while let last = skillName.last, ".,!?".contains(last) { skillName.removeLast() }
                let result = SkillStore.enable(skillName.trimmingCharacters(in: .whitespacesAndNewlines))
                print("[SKILL] \(result)")
                speak(result)
                hud.show("✓ \(result)")
                finishLane(.reflex, start: laneStart, raw: raw)
                state = .idle
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); hud.hide() }
                return
            }
        }

        // 2. Grab the active selection when referenced.
        if raw.lowercased().contains("selection") || raw.lowercased().contains("selected text") {
            let sel = await injector.grabActiveSelection(targetPID: lastActiveApp?.processIdentifier)
            print("[JARVIS] Grabbed selection: '\(sel ?? "none")'")
        }

        // 3. Zero-latency deterministic shortcuts (native Swift actions, no LLM).
        if let shortcut = CommandEngine.checkZeroLatencyShortcut(for: raw) {
            await runZeroLatencyShortcut(shortcut)
            finishLane(.reflex, start: laneStart, raw: raw)
            return
        }

        // 3b. Deterministic weather — never let the small model fumble an obvious weather
        // ask (it sometimes hallucinates "permission denied" for a keyless API). Call the
        // service directly and present it in the glass card.
        if let city = Self.weatherCity(in: raw) {
            hud.show("🌤  Weather…")
            let summary = await WeatherService.summary(city: city) ?? "Couldn't get the weather for \(city) right now."
            print("[JARVIS] Deterministic weather (\(city)): \(summary)")
            hud.showResult("\(summary)\n\(Quips.weatherTail())")   // data on screen, wit underneath
            speak(shortSpoken(summary))
            TaskJournal.record(command: raw, reply: summary)
            finishLane(.reflex, start: laneStart, raw: raw)
            state = .idle
            Task { try? await Task.sleep(nanoseconds: 2_500_000_000); hud.hide() }
            return
        }

        // 3c. Kernel reflex router — the registry picks the cheapest capable path. If
        // that path is a pure-Swift reflex (e.g. "open xcode", or a compound like
        // "open finder and open xcode"), execute it here with ZERO tokens instead of
        // waking the model. Anything above reflex tier returns nil and falls through.
        if let reflexReply = await Kernel.shared.dispatchCompound(raw) {
            print("[JARVIS] Kernel reflex: \(reflexReply)")
            hud.showResult(reflexReply)
            speak(shortSpoken(reflexReply))
            TaskJournal.record(command: raw, reply: reflexReply)
            await ConversationMemory.shared.record(user: raw, assistant: reflexReply)
            finishLane(.reflex, start: laneStart, raw: raw)
            state = .idle
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); hud.hide() }
            return
        }

        // 4. Native Apple Intelligence agent (tool calling) — the catch-all brain.
        var agentError: Error? = nil
        if SettingsController.apiProvider.lowercased() == "apple",
           #available(macOS 26.0, *), JarvisAgent.isAvailable() {
            state = .polishing
            hud.show("✨  Jarvis…")
            do {
                let reply: String
                if let coord = self.coordinator as? CoordinatorAgent {
                    reply = Self.sanitizeReply(try await coord.handleTurn(userInput: raw))
                } else {
                    reply = Self.sanitizeReply(try await JarvisAgent.run(raw))
                }
                print("[JARVIS] Agent reply: '\(reply)'")
                DatasetLogger.shared.log(mode: "jarvis-apple", app: lastActiveApp?.localizedName, rawTranscript: raw, response: reply, kind: "agent", samples: samples)
                TaskJournal.record(command: raw, reply: reply)
                await ConversationMemory.shared.record(user: raw, assistant: reply)
                finishLane(.apple, start: laneStart, raw: raw)
                presentJarvisReply(reply, raw: raw)
                return
            } catch {
                agentError = error
                print("[JARVIS] Agent failed (\(error.localizedDescription)); trying orchestrator.")
            }
        }

        // 5. Deterministic browser-orchestration (Claude popover) commands.
        if let action = CommandEngine.orchestratorAction(for: raw) {
            print("[JARVIS] Orchestrator command: \(action)")
            DatasetLogger.shared.log(mode: "orchestrator", app: lastActiveApp?.localizedName, rawTranscript: raw, response: "\(action)", kind: "orchestrator", samples: samples)
            switch action {
            case .claudeNewChat:
                hud.show("🔑 Summoning Claude popover…")
                speak("Claude popover खोल रहा हूँ बॉस।")
                await ClaudeQuickEntry.send("")
            case .prepPrompt(let useCase):
                await handlePrepPrompt(useCase)
            case .sendLastPromptToClaude:
                await handleSendLastPrompt()
            }
            finishLane(.reflex, start: laneStart, raw: raw)
            state = .idle
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); hud.hide() }
            return
        }

        // 6. Nothing matched — report why Jarvis couldn't act.
        let errorMessage: String
        if let err = agentError { errorMessage = err.localizedDescription }
        else if let availErr = JarvisAgent.availabilityError() { errorMessage = availErr }
        else { errorMessage = "Apple Intelligence is unavailable on this machine." }
        print("[JARVIS] Failed: \(errorMessage)")
        hud.show("⚠️ Jarvis Error")
        speak("Jarvis is unavailable. \(errorMessage)")
        finishLane(.failed, start: laneStart, raw: raw)
        state = .idle
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); hud.hide() }
    }

    /// Executes a matched zero-latency shortcut (native actions / system info report).
    private func runZeroLatencyShortcut(_ shortcut: CommandEngine.ZeroLatencyShortcut) async {
        print("[JARVIS] Zero-latency shortcut: \(shortcut.hudMessage)")
        state = .polishing
        hud.show("✨ \(shortcut.hudMessage)…")

        let output: String
        if shortcut.command.hasPrefix("native:") {
            let action = String(shortcut.command.dropFirst(7))
            // Parametric reflexes carry their value after a colon: "set_volume:90".
            if action.hasPrefix("set_volume:"), let pct = Int(action.dropFirst("set_volume:".count)) {
                _ = SystemControlHelper.setVolume(Float(pct))      // setter takes 0…100
                output = "Volume \(pct)%"
            } else if action.hasPrefix("set_brightness:"), let pct = Int(action.dropFirst("set_brightness:".count)) {
                _ = SystemControlHelper.setBrightness(Float(pct) / 100.0)  // setter takes 0.0…1.0
                output = "Brightness \(pct)%"
            } else {
            switch action {
            case "mute": SystemControlHelper.setMuted(true); output = "Muted"
            case "unmute": SystemControlHelper.setMuted(false); output = "Unmuted"
            case "volume_up": SystemControlHelper.setVolume(SystemControlHelper.getVolume() + 10.0); output = "Volume Set"
            case "volume_down": SystemControlHelper.setVolume(SystemControlHelper.getVolume() - 10.0); output = "Volume Set"
            case "brightness_up": SystemControlHelper.setBrightness(SystemControlHelper.getBrightness() + 0.1); output = "Brightness Set"
            case "brightness_down": SystemControlHelper.setBrightness(SystemControlHelper.getBrightness() - 0.1); output = "Brightness Set"
            case "system_info":
                let battery = SystemDiagnostics.getBatteryPercentage()
                let wifi = SystemDiagnostics.getWifiSSID()
                let disk = SystemDiagnostics.getFreeDiskSpace()
                output = "# System Status Report\n\n- **Battery**: \(battery)\n- **Wi-Fi SSID**: \(wifi)\n- **Free Disk Space**: \(disk)\n"
                speak("मिस्टर लॉर्ड, battery \(battery) पर है, Wi-Fi network '\(wifi)' से connected है, और disk पर \(disk) space खाली है। दिल्ली से हूँ भाई, सब चकाचक चल रहा है।")
            case "ram_info":
                let ram = SystemDiagnostics.getRAMUsage()
                let hogs = SystemDiagnostics.getTopMemoryProcesses()
                var report = "# 🧠 RAM Memory Status\n\n"
                report += "- **Total RAM**: \(String(format: "%.2f", ram.totalGB)) GB\n"
                report += "- **Used RAM**: \(String(format: "%.2f", ram.totalGB - ram.freeGB)) GB (\(String(format: "%.1f", ram.usedPercent))%)\n"
                report += "- **Free RAM**: \(String(format: "%.2f", ram.freeGB)) GB\n"
                report += "- **Wired (System)**: \(String(format: "%.2f", ram.wiredGB)) GB\n"
                report += "- **Active (App)**: \(String(format: "%.2f", ram.activeGB)) GB\n"
                report += "- **Compressed**: \(String(format: "%.2f", ram.compressedGB)) GB\n\n"
                report += "## 🏆 Top Memory Consumers\n\n| Process Name | Memory Usage |\n| :--- | :--- |\n"
                report += hogs
                output = report
            default:
                output = await NativeActions.perform(action)
            }
            }
        } else {
            output = CommandEngine.runCommandNatively(shortcut.command)
        }
        print("[JARVIS] Zero-latency output: \(output)")

        if shortcut.hudMessage == "List of Tabs" && !output.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        }
        if !shortcut.voiceFeedback.isEmpty { speak(shortcut.voiceFeedback) }
        if shortcut.showOutputInWindow { explanationController.show(text: output, title: shortcut.windowTitle) }

        hud.show("✓ \(shortcut.hudMessage)")
        state = .idle
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); hud.hide() }
    }

    private func writeNoteFile(filename: String, content: String) {
        let fileManager = FileManager.default
        let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let sottoNotesURL = desktopURL.appendingPathComponent("SottoNotes")
        
        do {
            if !fileManager.fileExists(atPath: sottoNotesURL.path) {
                try fileManager.createDirectory(at: sottoNotesURL, withIntermediateDirectories: true, attributes: nil)
            }
            let fileURL = sottoNotesURL.appendingPathComponent(filename)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            print("[AGENT] Note saved successfully to \(fileURL.path)")
        } catch {
            print("[AGENT] Failed to write note: \(error.localizedDescription)")
        }
    }

    private func getBestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let excludedKeywords = ["cello", "novelty", "bell", "organ", "zarvox", "bubbles", "hysterical", "whisper", "bad_news", "trinoids", "deranged", "pipe", "reed"]
        
        let englishVoices = allVoices.filter { voice in
            let lang = voice.language.lowercased()
            let id = voice.identifier.lowercased()
            let name = voice.name.lowercased()
            let isEnglish = lang.hasPrefix("en-")
            let isExcluded = excludedKeywords.contains { kw in id.contains(kw) || name.contains(kw) }
            return isEnglish && !isExcluded
        }
        
        // 1. Try to find "Daniel" (British English, sounds like Jarvis)
        if let daniel = englishVoices.first(where: { $0.name.lowercased().contains("daniel") }) {
            return daniel
        }
        
        // 2. Try to find "Alex" (Premium American English)
        if let alex = englishVoices.first(where: { $0.name.lowercased().contains("alex") }) {
            return alex
        }
        
        // 3. Try to find "Samantha" (Clear American English)
        if let samantha = englishVoices.first(where: { $0.name.lowercased().contains("samantha") }) {
            return samantha
        }
        
        // 4. Try any English male voice
        if let maleVoice = englishVoices.first(where: { $0.gender == .male }) {
            return maleVoice
        }
        
        // 5. Try any English female voice
        if let femaleVoice = englishVoices.first(where: { $0.gender == .female }) {
            return femaleVoice
        }
        
        return englishVoices.first
    }

    private func speakWithSystemSynthesizer(_ text: String) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        let voiceId = SettingsController.voiceIdentifier
        
        var voiceToUse: AVSpeechSynthesisVoice? = nil
        let excludedKeywords = ["cello", "novelty", "bell", "organ", "zarvox", "bubbles", "hysterical", "whisper", "bad_news", "trinoids", "deranged", "pipe", "reed"]
        
        if let selectedVoice = AVSpeechSynthesisVoice(identifier: voiceId) {
            let lowerId = selectedVoice.identifier.lowercased()
            let lowerName = selectedVoice.name.lowercased()
            let isExcluded = excludedKeywords.contains { kw in lowerId.contains(kw) || lowerName.contains(kw) }
            if !isExcluded {
                voiceToUse = selectedVoice
            }
        }
        
        if voiceToUse == nil {
            voiceToUse = getBestEnglishVoice()
        }
        
        utterance.voice = voiceToUse
        utterance.rate = SettingsController.speechRate
        utterance.pitchMultiplier = SettingsController.speechPitch
        speechSynthesizer.speak(utterance)
    }

    func speak(_ text: String) {
        guard SettingsController.isVoiceFeedbackEnabled else { return }

        // Always stop any playing sound or speech first
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        if let activeSound {
            activeSound.stop()
            self.activeSound = nil
        }

        // Voice feedback is 100% native via AVSpeechSynthesizer — no Python TTS daemon.
        speakWithSystemSynthesizer(text)
    }

    @MainActor
    private func handleIncomingCommandText(_ text: String) async {
        print("[APP] Received external command text: '\(text)'")
        state = .transcribing
        hud.show("…  Processing command")
        
        let context = ContextDetector.current()
        let output = await CommandEngine.process(text, context: context, selection: nil)
        let processedText = output.text
        
        // External commands (sotto:// URL scheme) run through the native Apple agent.
        if !processedText.isEmpty,
           SettingsController.apiProvider.lowercased() == "apple",
           #available(macOS 26.0, *),
           JarvisAgent.isAvailable() {
            self.state = .polishing
            self.hud.show("✨  Jarvis…")
            do {
                let reply: String
                if let coord = self.coordinator as? CoordinatorAgent {
                    reply = Self.sanitizeReply(try await coord.handleTurn(userInput: processedText))
                } else {
                    reply = Self.sanitizeReply(try await JarvisAgent.run(processedText))
                }
                DatasetLogger.shared.log(mode: "jarvis-url", app: self.lastActiveApp?.localizedName, rawTranscript: processedText, response: reply, kind: "agent", samples: nil)
                TaskJournal.record(command: processedText, reply: reply)
                if reply.isEmpty {
                    self.hud.show("✓ Done")
                } else {
                    self.hud.show("🗣 \(reply)")
                    self.speak(reply)
                }
                self.state = .idle
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.hud.hide() }
                return
            } catch {
                print("[AGENT] Apple agent (URL command) failed: \(error.localizedDescription)")
            }
        }

        if !processedText.isEmpty || output.fileURL != nil || output.searchShortcut != nil {
            if let app = self.lastActiveApp {
                if #available(macOS 14.0, *) {
                    NSApplication.shared.yieldActivation(to: app)
                }
                app.activate(options: [])
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            
            if output.delayBeforeInject > 0 {
                try? await Task.sleep(nanoseconds: UInt64(output.delayBeforeInject * 1_000_000_000))
            }
            
            if let shortcut = output.searchShortcut {
                await self.injector.pressSearchShortcut(shortcut, targetPID: self.lastActiveApp?.processIdentifier)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            
            if !processedText.isEmpty || output.fileURL != nil {
                await self.injector.inject(processedText, fileURL: output.fileURL, targetPID: self.lastActiveApp?.processIdentifier)
            }
            
            if output.pressReturnAfter {
                try? await Task.sleep(nanoseconds: 350_000_000)
                await self.injector.pressReturn(targetPID: self.lastActiveApp?.processIdentifier)
            }
            
            self.statusBar.lastTranscript = processedText
            self.hud.show("✓ Done")
            self.state = .idle
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.hud.hide()
            }
        } else {
            self.state = .idle
            self.hud.hide()
        }
    }

    /// Builds a Claude-ready prompt from the use case (capturing the screen via OCR
    /// when relevant), saves it, and shows it for review before sending.
    @MainActor
    private func handlePrepPrompt(_ useCase: PromptUseCase) async {
        var screenText: String? = nil
        if useCase.needsScreenContext {
            self.hud.show("📸 Reading your screen…")
            screenText = await CommandEngine.ocrScreen()
        }

        let prepped = PromptBuilder.build(useCase, screenText: screenText)
        PromptStore.save(prepped)

        self.hud.show("📝 Prompt ready — review it")
        self.speak("Prompt तैयार है बॉस, ज़रा देख लो फिर भेजते हैं।")

        self.promptReview.show(prompt: prepped) { [weak self] editedText in
            guard let self else { return }
            Task { @MainActor in
                self.hud.show("📋 Sending to Claude popover…")
                self.speak("Claude popover में भेज रहा हूँ बॉस।")
                await ClaudeQuickEntry.send(editedText)
                self.hud.show("✓ Sent to Claude popover")
            }
        }
    }

    /// Sends the most recently prepared prompt to Claude (batch step 2).
    @MainActor
    private func handleSendLastPrompt() async {
        guard let last = PromptStore.loadLast() else {
            self.hud.show("⚠️ No prepared prompt saved")
            self.speak("कोई prompt तैयार नहीं है बॉस, पहले prep करो।")
            return
        }
        self.hud.show("📋 Sending to Claude popover…")
        self.speak("Claude popover में भेज रहा हूँ बॉस।")
        await ClaudeQuickEntry.send(last.assembledText)
        self.hud.show("✓ Sent to Claude popover")
    }

    private func scheduleErrorRecovery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, case .error = self.state else { return }
            self.state = .idle
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

    private func learnFromDictation(raw: String, polished: String) {
        let cleanRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPolished = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanRaw.isEmpty && !cleanPolished.isEmpty else { return }
        
        // Don't learn style if the polished text still contains obvious filler words, disfluencies, or placeholders
        let lowerPolished = cleanPolished.lowercased()
        let fillerCheckWords = lowerPolished.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let fillerWords: Set<String> = ["um", "uh", "ah", "umh", "blah"]
        for word in fillerCheckWords {
            if fillerWords.contains(word) {
                print("[LEARNING] Skipping learning: Polished text still contains filler '\(word)'")
                return
            }
        }
        if lowerPolished.contains("something like that") {
            print("[LEARNING] Skipping learning: Polished text still contains filler 'something like that'")
            return
        }
        
        // 1. Learn Style Examples (only if they are structurally different, meaning actual word cleaning occurred)
        let normRaw = cleanRaw.lowercased().filter { $0.isLetter || $0.isNumber }
        let normPolished = cleanPolished.lowercased().filter { $0.isLetter || $0.isNumber }
        if normRaw != normPolished {
            // Don't learn style if the polished text has repetitive loops
            if hasRepetitiveLoops(cleanPolished) {
                print("[LEARNING] Skipping learning: Polished text contains repetitive loops")
                return
            }
            
            // Don't learn style if the polished text is excessively long (hallucinated)
            let rawWords = cleanRaw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let polishedWords = cleanPolished.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if rawWords.count >= 6 && Double(polishedWords.count) > Double(rawWords.count) * 2.5 {
                print("[LEARNING] Skipping learning: Polished text is excessively long compared to raw text")
                return
            }

            var examples: [DictationExample] = []
            if let data = UserDefaults.standard.data(forKey: "sotto_style_examples"),
               let decoded = try? JSONDecoder().decode([DictationExample].self, from: data) {
                examples = decoded
            }
            
            // Check if this example is already in the list
            if !examples.contains(where: { $0.raw == cleanRaw && $0.polished == cleanPolished }) {
                examples.append(DictationExample(raw: cleanRaw, polished: cleanPolished))
                if examples.count > 5 {
                    examples.removeFirst()
                }
                if let encoded = try? JSONEncoder().encode(examples) {
                    UserDefaults.standard.set(encoded, forKey: "sotto_style_examples")
                    print("[LEARNING] Saved new dictation style example: \(cleanRaw) -> \(cleanPolished)")
                }
            }
        }
        
        // 2. Learn Vocabulary / Jargon (Proper nouns, camelCase, technical terms, acronyms)
        let words = cleanPolished.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var newJargon: Set<String> = []
        for (idx, word) in words.enumerated() {
            guard word.count >= 3 else { continue }

            let isFirstWord = (idx == 0)
            let hasNumber = word.contains { $0.isNumber }
            let isAllUppercase = word == word.uppercased()
            let hasInternalCapitals = word.dropFirst().contains { $0.isUppercase }

            // Only learn genuine jargon: ACRONYMS (CSRD), camelCase / internal caps
            // (FaceTime), or alphanumeric tokens (HRV2). A plain Capitalized word is
            // usually just a sentence start or a common word ("Because", "Check"), so
            // it is learned only when it is NOT a common English word and not first.
            let looksLikeJargon = isAllUppercase || hasInternalCapitals || hasNumber
            let isPlainCapitalized = !isFirstWord && (word.first?.isUppercase ?? false)
                && !Self.commonWordStopList.contains(word.lowercased())

            if looksLikeJargon || isPlainCapitalized {
                if !Self.commonWordStopList.contains(word.lowercased()) {
                    newJargon.insert(word)
                }
            }
        }

        if !newJargon.isEmpty {
            let existing = UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? []
            // Case-insensitive dedup: keep one variant per word, preferring the one with
            // more uppercase letters (so "CSRD" wins over "Csrd").
            var byKey: [String: String] = [:]
            for term in existing + Array(newJargon) {
                let key = term.lowercased()
                if let current = byKey[key] {
                    let curUpper = current.filter { $0.isUppercase }.count
                    let newUpper = term.filter { $0.isUppercase }.count
                    if newUpper > curUpper { byKey[key] = term }
                } else {
                    byKey[key] = term
                }
            }
            var vocabArray = byKey.values.sorted()
            if vocabArray.count > 100 { vocabArray = Array(vocabArray.prefix(100)) }
            if vocabArray != existing.sorted() {
                UserDefaults.standard.set(vocabArray, forKey: "sotto_learned_vocabulary")
                print("[LEARNING] Learned new vocabulary terms: \(newJargon)")
            }
        }
    }

    /// Common English words that are NOT jargon even when capitalized (sentence starts,
    /// fillers, frequent words). Kept lowercased for case-insensitive matching.
    private static let commonWordStopList: Set<String> = [
        "and", "the", "you", "for", "not", "but", "get", "set", "out", "yes", "yeah",
        "yep", "nope", "okay", "this", "that", "these", "those", "what", "when", "where",
        "why", "who", "which", "then", "there", "here", "now", "just", "also", "with",
        "from", "into", "about", "over", "under", "after", "before", "some", "any", "all",
        "have", "has", "had", "will", "would", "could", "should", "can", "may", "might",
        "must", "want", "need", "please", "well", "actually", "maybe", "really", "very",
        "too", "let", "lets", "because", "check", "make", "like", "how", "hey", "say",
        "tell", "ask", "open", "start", "stop", "thanks", "thank", "sure", "fine"
    ]

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
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .centerY
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        
        if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Explanation") {
            let iv = NSImageView(image: image)
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            iv.contentTintColor = NSColor.controlAccentColor
            headerStack.addArrangedSubview(iv)
        }
        
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

fileprivate func hasRepetitiveLoops(_ text: String) -> Bool {
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
