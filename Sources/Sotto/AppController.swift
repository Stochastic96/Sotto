import AppKit
import AVFoundation

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
    private var visualizerTimer: Timer?
    private var recordingStart: Date?
    private var recentTranscripts: [String] = []
    private var lastActiveApp: NSRunningApplication?
    private var appActivity: NSObjectProtocol?

    enum Mode {
        case dictation
        case jarvis
    }
    private var currentMode: Mode = .dictation

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
        didSet { statusBar.update(for: state) }
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

        // Warm the on-device Apple Intelligence model so the first dictation/agent call
        // has no cold-start latency.
        JarvisAgent.prewarm()

        print("[SOTTO-APP] Creating HotkeyListener...")
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
                NSLog("Sotto: microphone access denied — dictation cannot work without it.")
            }
        }
        // Accessibility — needed for the global hotkey tap and synthetic ⌘V.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("Sotto: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility).")
        }
        // Screen Recording — needed for Screen OCR.
        if #available(macOS 10.15, *) {
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
                NSLog("Sotto: waiting for Screen Recording permission (System Settings → Privacy & Security → Screen Recording).")
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

        // Capture the focused app *now*, before transcription finishes —
        // focus may change while the model runs.
        let context = ContextDetector.current()

        Task { @MainActor in
            let pipelineStart = CFAbsoluteTimeGetCurrent()
            var showedSuccessHUD = false
            
            defer {
                if !showedSuccessHUD {
                    self.hud.hide()
                }
            }
            
            // Ignore accidental taps shorter than ~0.3s of audio.
            guard samples.count > 4800 else {
                self.state = .idle
                return
            }
            do {
                let transcribeStart = CFAbsoluteTimeGetCurrent()
                let raw = try await self.transcriber.transcribe(samples)
                let transcribeDuration = CFAbsoluteTimeGetCurrent() - transcribeStart
                print("[APP] Raw Whisper Transcript: '\(raw)'")
                print("[AGENT-DEBUG] currentMode is '\(self.currentMode)', qwen is nil: \(self.qwen == nil)")

                // User-only approval gate: speaking this is the ONLY way a Jarvis-drafted
                // skill becomes runnable. The agent can draft skills but cannot enable its own.
                let lowerRawForApproval = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["enable skill ", "approve skill ", "activate skill "] {
                    if lowerRawForApproval.hasPrefix(prefix) {
                        var skillName = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(prefix.count))
                        while let last = skillName.last, ".,!?".contains(last) { skillName.removeLast() }
                        let result = SkillStore.enable(skillName.trimmingCharacters(in: .whitespacesAndNewlines))
                        print("[SKILL] \(result)")
                        self.speak(result)
                        self.hud.show("✓ \(result)")
                        showedSuccessHUD = true
                        self.state = .idle
                        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.hud.hide() }
                        return
                    }
                }

                var selectionText: String? = nil
                let lowerRaw = raw.lowercased()
                if lowerRaw.contains("selection") || lowerRaw.contains("selected text") {
                    selectionText = await self.injector.grabActiveSelection(targetPID: self.lastActiveApp?.processIdentifier)
                    print("[APP] Grabbed selection: '\(selectionText ?? "none")'")
                }

                // Zero-latency local shortcuts (e.g. window management, browser tab navigation, system controls)
                if let shortcut = CommandEngine.checkZeroLatencyShortcut(for: raw) {
                    print("[APP] Zero-latency shortcut matched: \(shortcut.hudMessage)")
                    self.state = .polishing
                    self.hud.show("✨ \(shortcut.hudMessage)…")
                    
                    let output: String
                    if shortcut.command.hasPrefix("native:") {
                        let action = String(shortcut.command.dropFirst(7))
                        switch action {
                        case "mute":
                            SystemControlHelper.setMuted(true)
                            output = "Muted"
                        case "unmute":
                            SystemControlHelper.setMuted(false)
                            output = "Unmuted"
                        case "volume_up":
                            let current = SystemControlHelper.getVolume()
                            SystemControlHelper.setVolume(current + 10.0)
                            output = "Volume Set"
                        case "volume_down":
                            let current = SystemControlHelper.getVolume()
                            SystemControlHelper.setVolume(current - 10.0)
                            output = "Volume Set"
                        case "brightness_up":
                            let current = SystemControlHelper.getBrightness()
                            SystemControlHelper.setBrightness(current + 0.1)
                            output = "Brightness Set"
                        case "brightness_down":
                            let current = SystemControlHelper.getBrightness()
                            SystemControlHelper.setBrightness(current - 0.1)
                            output = "Brightness Set"
                        case "system_info":
                            let battery = SystemDiagnostics.getBatteryPercentage()
                            let wifi = SystemDiagnostics.getWifiSSID()
                            let disk = SystemDiagnostics.getFreeDiskSpace()
                            output = "# System Status Report\n\n- **Battery**: \(battery)\n- **Wi-Fi SSID**: \(wifi)\n- **Free Disk Space**: \(disk)\n"
                            let voice = "मिस्टर लॉर्ड, battery \(battery) पर है, Wi-Fi network '\(wifi)' से connected है, और disk पर \(disk) space खाली है। दिल्ली से हूँ भाई, सब चकाचक चल रहा है।"
                            self.speak(voice)
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
                            report += "## 🏆 Top Memory Consumers\n\n"
                            report += "| Process Name | Memory Usage |\n"
                            report += "| :--- | :--- |\n"
                            report += hogs
                            output = report
                        default:
                            // Window management, media keys, browser nav, appearance,
                            // sleep/lock/trash — all native Swift (see NativeActions).
                            output = await NativeActions.perform(action)
                        }
                    } else {
                        output = CommandEngine.runCommandNatively(shortcut.command)
                    }
                    print("[APP] Zero-latency command output: \(output)")
                    
                    // If listing tabs, copy the output to general clipboard
                    if shortcut.hudMessage == "List of Tabs" && !output.isEmpty {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(output, forType: .string)
                    }
                    
                    if !shortcut.voiceFeedback.isEmpty {
                        self.speak(shortcut.voiceFeedback)
                    }
                    
                    if shortcut.showOutputInWindow {
                        self.explanationController.show(text: output, title: shortcut.windowTitle)
                    }
                    
                    self.hud.show("✓ \(shortcut.hudMessage)")
                    self.state = .idle
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        self.hud.hide()
                    }
                    return
                }

                var agentError: Error? = nil
                
                // Native Apple Intelligence agent (tool calling) — in Jarvis mode on the Apple
                // provider, the on-device model OWNS routing: it picks and calls JarvisToolbox
                // tools (including ask_claude → the Claude desktop quick-entry popover). Runs
                // BEFORE the legacy web-orchestrator so "research X on Claude" goes to the
                // popover, not the old Chrome/claude.ai sign-in flow. Falls through on failure.
                if self.currentMode == .jarvis,
                   SettingsController.apiProvider.lowercased() == "apple",
                   #available(macOS 26.0, *),
                   JarvisAgent.isAvailable() {
                    print("[AGENT-DEBUG] Entered native Apple Jarvis agent path.")
                    self.state = .polishing
                    self.hud.show("✨  Jarvis…")
                    do {
                        let reply = try await JarvisAgent.run(raw)
                        print("[AGENT-DEBUG] Apple Jarvis reply: '\(reply)'")
                        DatasetLogger.shared.log(mode: "jarvis-apple", app: self.lastActiveApp?.localizedName, rawTranscript: raw, response: reply, kind: "agent", samples: samples)
                        TaskJournal.record(command: raw, reply: reply)
                        showedSuccessHUD = true
                        if reply.isEmpty {
                            self.hud.show("✓ Done")
                        } else {
                            self.hud.show("🗣 \(reply)")
                            self.speak(reply)
                        }
                        self.state = .idle
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            self.hud.hide()
                        }
                        return
                    } catch {
                        agentError = error
                        print("[AGENT] Apple Jarvis agent failed (\(error.localizedDescription)); falling back to legacy paths.")
                    }
                }

                // Deterministic, zero-token browser-orchestration commands (e.g. "open Claude").
                // Matched before any Qwen call, so they run instantly in both dictation and Jarvis modes.
                if let action = CommandEngine.orchestratorAction(for: raw) {
                    print("[APP] Orchestrator command recognized: \(action)")
                    DatasetLogger.shared.log(mode: "orchestrator", app: self.lastActiveApp?.localizedName, rawTranscript: raw, response: "\(action)", kind: "orchestrator", samples: samples)
                    showedSuccessHUD = true
                    switch action {
                    case .claudeNewChat:
                        self.hud.show("🔑 Summoning Claude popover…")
                        self.speak("Claude popover खोल रहा हूँ बॉस।")
                        await ClaudeQuickEntry.send("")
                    case .prepPrompt(let useCase):
                        await self.handlePrepPrompt(useCase)
                    case .sendLastPromptToClaude:
                        await self.handleSendLastPrompt()
                    }
                    self.state = .idle
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self.hud.hide()
                    }
                    return
                }

                // Jarvis mode is powered by the native Apple Intelligence agent above.
                // If we reached here in Jarvis mode, Apple Intelligence wasn't available —
                // report the exact error/availability problem to the user.
                if self.currentMode == .jarvis {
                    let errorMessage: String
                    if let err = agentError {
                        errorMessage = err.localizedDescription
                    } else if let availErr = JarvisAgent.availabilityError() {
                        errorMessage = availErr
                    } else {
                        errorMessage = "Apple Intelligence is unavailable on this machine."
                    }
                    print("[AGENT] Jarvis mode failed: \(errorMessage)")
                    self.hud.show("⚠️ Jarvis Error")
                    self.speak("Jarvis is unavailable. \(errorMessage)")
                    showedSuccessHUD = true
                    self.state = .idle
                    Task { try? await Task.sleep(nanoseconds: 3_500_000_000); self.hud.hide() }
                    return
                }

                let output = await CommandEngine.process(raw, context: context, selection: selectionText)
                var text = output.text
                
                var polishDuration = 0.0

                if self.polishEnabled, !text.isEmpty, let qwen = self.qwen {
                    self.state = .polishing
                    self.hud.show("✨  Polishing…")
                    let polishStart = CFAbsoluteTimeGetCurrent()
                    do {
                        let polished = try await withThrowingTaskGroup(of: String.self) { group in
                            group.addTask {
                                try await qwen.refine(text, context: context, history: self.recentTranscripts)
                            }
                            group.addTask {
                                try await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds timeout
                                throw NSError(domain: "SottoQwen", code: -1, userInfo: [NSLocalizedDescriptionKey: "AI Polish timed out"])
                            }
                            guard let result = try await group.next() else {
                                throw NSError(domain: "SottoQwen", code: -2, userInfo: [NSLocalizedDescriptionKey: "No result returned"])
                            }
                            group.cancelAll()
                            return result
                        }
                        
                        let originalWords = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                        let polishedWords = polished.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                        
                        if polished.isEmpty {
                            print("[APP] AI Polish returned empty string. Falling back to raw text.")
                        } else if (polishedWords.count < originalWords.count / 3) || (originalWords.count >= 8 && polishedWords.count <= 2) {
                            print("[APP] AI Polish truncated output drastically (original words: \(originalWords.count), polished words: \(polishedWords.count), polished: '\(polished)'). Falling back to raw text.")
                        } else if (Double(polishedWords.count) > Double(originalWords.count) * 2.5) && originalWords.count >= 6 {
                            print("[APP] AI Polish expanded output drastically (original words: \(originalWords.count), polished words: \(polishedWords.count), polished: '\(polished)'). Likely hallucination or loop. Falling back to raw text.")
                        } else if hasRepetitiveLoops(polished) {
                            print("[APP] AI Polish contains repetitive loops. Falling back to raw text.")
                        } else {
                            text = polished
                        }
                    } catch {
                        print("[APP] AI Polish failed or timed out: \(error.localizedDescription). Using raw text.")
                    }
                    polishDuration = CFAbsoluteTimeGetCurrent() - polishStart
                }

                if output.showLocalExplanation {
                    self.state = .polishing
                    self.hud.show("✨  AI Thinking…")
                    var explanationText = ""
                    if let qwen = self.qwen {
                        do {
                            let result = try await qwen.refine(text, context: context, history: [])
                            explanationText = result
                        } catch {
                            explanationText = "Local AI failed to generate explanation: \(error.localizedDescription)"
                        }
                    } else {
                        explanationText = "Local AI model is not loaded."
                    }
                    
                    self.state = .idle
                    self.hud.show("✓ Done")
                    
                    // Display locally in Sotto window
                    self.explanationController.show(text: explanationText, title: output.explanationTitle)
                    
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        self.hud.hide()
                    }
                    return
                }

                if !text.isEmpty || output.fileURL != nil || output.searchShortcut != nil {
                    print("[APP] Content ready for injection: '\(text)' (file: \(output.fileURL?.path ?? "none"), searchShortcut: \(output.searchShortcut?.rawValue ?? "none"), pressReturn: \(output.pressReturnAfter))")
                    NSSound(named: "Tink")?.play()

                    if let app = self.lastActiveApp {
                        print("[APP] Reactivating target application: \(app.localizedName ?? "unknown")")
                        if #available(macOS 14.0, *) {
                            NSApplication.shared.yieldActivation(to: app)
                        }
                        app.activate(options: [])
                        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms delay for window focus shift
                    }

                    if output.delayBeforeInject > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(output.delayBeforeInject * 1_000_000_000))
                    }

                    if let shortcut = output.searchShortcut {
                        await self.injector.pressSearchShortcut(shortcut, targetPID: self.lastActiveApp?.processIdentifier)
                        // Wait for search field to open and focus
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                    }

                    if !text.isEmpty || output.fileURL != nil {
                        await self.injector.inject(text, fileURL: output.fileURL, targetPID: self.lastActiveApp?.processIdentifier)
                    }

                    if output.pressReturnAfter {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        await self.injector.pressReturn(targetPID: self.lastActiveApp?.processIdentifier)
                    }
                    self.statusBar.lastTranscript = text
                    if !text.isEmpty {
                        self.recentTranscripts.append(text)
                        if self.recentTranscripts.count > 5 {
                            self.recentTranscripts.removeFirst()
                        }
                        self.learnFromDictation(raw: raw, polished: text)
                    }
                    DatasetLogger.shared.log(mode: "dictation", app: self.lastActiveApp?.localizedName, rawTranscript: raw, response: text, kind: "polish", samples: samples)

                    let totalDuration = CFAbsoluteTimeGetCurrent() - pipelineStart
                    print("[BENCHMARK] Pipeline executed successfully in \(String(format: "%.2f", totalDuration * 1000))ms (Whisper: \(String(format: "%.2f", transcribeDuration * 1000))ms, Qwen: \(String(format: "%.2f", polishDuration * 1000))ms)")
                    
                    self.hud.show("✓ Done (\(String(format: "%.1f", totalDuration))s)")
                    showedSuccessHUD = true
                    
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                        self.hud.hide()
                    }
                } else {
                    print("[APP] Transcript, search shortcut, and file URL are empty, skipping injection")
                }
                self.state = .idle
            } catch {
                NSSound(named: "Basso")?.play()
                self.state = .error("Transcription failed: \(error.localizedDescription)")
                self.scheduleErrorRecovery()
            }
        }
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
                let reply = try await JarvisAgent.run(processedText)
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
            screenText = CommandEngine.ocrScreen()
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
        let fillerWords = ["um", "uh", "ah", "umh", "blah", "something like that"]
        for filler in fillerWords {
            if lowerPolished.contains(filler) {
                print("[LEARNING] Skipping learning: Polished text still contains filler '\(filler)'")
                return
            }
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
            let firstChar = word.first!
            let hasNumber = word.contains { $0.isNumber }
            let isAllUppercase = word == word.uppercased()
            let hasInternalCapitals = word.dropFirst().contains { $0.isUppercase }
            let isCapitalized = firstChar.isUppercase
            
            if (!isFirstWord && isCapitalized) || isAllUppercase || hasInternalCapitals || hasNumber {
                let ignoreList: Set<String> = ["AND", "THE", "YOU", "FOR", "NOT", "BUT", "GET", "SET", "OUT", "YES"]
                if !ignoreList.contains(word.uppercased()) {
                    newJargon.insert(word)
                }
            }
        }
        
        if !newJargon.isEmpty {
            var learnedVocab = Set(UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? [])
            let beforeCount = learnedVocab.count
            learnedVocab.formUnion(newJargon)
            
            if learnedVocab.count > beforeCount {
                var vocabArray = Array(learnedVocab).sorted()
                if vocabArray.count > 100 {
                    vocabArray = Array(vocabArray.prefix(100))
                }
                UserDefaults.standard.set(vocabArray, forKey: "sotto_learned_vocabulary")
                print("[LEARNING] Learned new vocabulary terms: \(newJargon)")
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
