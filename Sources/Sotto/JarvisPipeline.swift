import AppKit
import AVFoundation
import SottoCore

extension AppController {
    
    // MARK: - Jarvis pipeline (⌘⇧J) — full OS assistant: skills, native actions, agent, orchestrator.

    /// Runs one Jarvis turn and returns the reply text that was surfaced to the user (empty when
    /// a branch produced no user-facing reply). The `@discardableResult` keeps the existing
    /// hotkey caller unchanged, while the dictation→Jarvis bridge uses the return value for its
    /// audit trail. `origin` tags the `DatasetLogger` entry so bridge-initiated turns are
    /// distinguishable from hotkey-initiated ones.
    @discardableResult
    func runJarvisPipeline(raw: String, samples: [Float], context: AppContext, origin: String = "jarvis-apple") async -> String {
        if await CooperativeWorkflowManager.shared.handleResponse(raw) {
            state = .idle
            return ""
        }

        let laneStart = CFAbsoluteTimeGetCurrent()
        
        // "lane stats" / "jarvis stats" — show the measured three-lane distribution.
        let lowerRaw = raw.lowercased()
        if lowerRaw.contains("lane stats") || lowerRaw.contains("jarvis stats") || lowerRaw.contains("performance stats") {
            let summary = await LaneStats.shared.summary()
            explanationController.show(text: summary, title: "Jarvis Lane Stats")
            hud.present(.info("Lane stats", detail: "Details opened in a window"))
            state = .idle
            Task { try? await Task.sleep(for: .seconds(1.5)); hud.hide() }
            return summary
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
                hud.present(.success(result))
                finishLane(.reflex, start: laneStart, raw: raw)
                state = .idle
                Task { try? await Task.sleep(for: .seconds(2)); hud.hide() }
                return result
            }
        }
        
        // 2. Grab the active selection when referenced.
        var processedInput = raw
        if raw.lowercased().contains("selection") || raw.lowercased().contains("selected text") {
            if let sel = await injector.grabActiveSelection(targetPID: lastActiveApp?.processIdentifier),
               !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                processedInput += "\n\n[Active Selection]\n\(sel)"
                print("[JARVIS] Appended active selection to input.")
            }
        }
        
        // 3. Grab the active selection when referenced.
        if let shortcut = CommandEngine.checkZeroLatencyShortcut(for: raw) {
            await runZeroLatencyShortcut(shortcut)
            finishLane(.reflex, start: laneStart, raw: raw)
            return shortcut.voiceFeedback.isEmpty ? shortcut.hudMessage : shortcut.voiceFeedback
        }
        
        // 3b. Deterministic weather — never let the small model fumble an obvious weather
        // ask (it sometimes hallucinates "permission denied" for a keyless API). Call the
        // service directly and present it in the glass card.
        if let city = Self.weatherCity(in: raw) {
            hud.present(.progress("Checking weather"))
            let summary = await WeatherService.summary(city: city) ?? "Couldn't get the weather for \(city) right now."
            print("[JARVIS] Deterministic weather (\(city)): \(summary)")
            hud.present(.info(summary, detail: Quips.weatherTail()), dismissAfter: 6)   // data on screen, wit underneath
            speak(shortSpoken(summary))
            TaskJournal.record(command: raw, reply: summary)
            finishLane(.reflex, start: laneStart, raw: raw)
            state = .idle
            Task { try? await Task.sleep(for: .seconds(2.5)); hud.hide() }
            return summary
        }
        
        // 3c. Kernel reflex router — the registry picks the cheapest capable path. If
        // that path is a pure-Swift reflex (e.g. "open xcode", or a compound like
        // "open finder and open xcode"), execute it here with ZERO tokens instead of
        // waking the model. Anything above reflex tier returns nil and falls through.
        if let reflexReply = await Kernel.shared.dispatchCompound(raw) {
            print("[JARVIS] Kernel reflex: \(reflexReply)")
            hud.present(.success(reflexReply), dismissAfter: 6)
            speak(shortSpoken(reflexReply))
            TaskJournal.record(command: raw, reply: reflexReply)
            await ConversationMemory.shared.record(user: raw, assistant: reflexReply)
            finishLane(.reflex, start: laneStart, raw: raw)
            state = .idle
            Task { try? await Task.sleep(for: .seconds(2)); hud.hide() }
            return reflexReply
        }
        
        // 3d. Jarvis Brain — associative command memory. Embeds the utterance with the
        // on-device NLEmbedding sentence model and matches remembered commands by
        // MEANING, so a learned/seeded command fires natively in any phrasing without
        // waking the model. A failed or declined action falls through to the LLM.
        if let hit = await JarvisBrain.shared.recall(utterance: raw),
           let brainReply = await runBrainAction(hit.action, raw: raw) {
            print("[JARVIS] Brain memory ('\(hit.phrase)'): \(brainReply)")
            hud.present(.reply("\(hit.phrase)\n\(brainReply)"))
            speak(shortSpoken(brainReply))
            TaskJournal.record(command: raw, reply: brainReply)
            await ConversationMemory.shared.record(user: raw, assistant: brainReply)
            finishLane(.reflex, start: laneStart, raw: raw)
            state = .idle
            Task { try? await Task.sleep(for: .seconds(2)); hud.hide() }
            return brainReply
        }

        // 4. Native Apple Intelligence agent (tool calling) — the catch-all brain.
        var agentError: Error? = nil
        if SettingsController.apiProvider.lowercased() == "apple",
           JarvisAgent.isAvailable() {
            state = .polishing
            hud.present(.thinking("Jarvis"), mode: .jarvis)
            do {
                let reply: String
                if let coord = self.coordinator {
                    reply = Self.sanitizeReply(try await coord.handleTurn(userInput: processedInput))
                } else {
                    reply = "Jarvis is still starting. Please try again in a moment."
                }
                print("[JARVIS] Agent reply: '\(reply)'")
                DatasetLogger.shared.log(mode: origin, app: lastActiveApp?.localizedName, rawTranscript: raw, response: reply, kind: "agent", samples: samples)
                TaskJournal.record(command: raw, reply: reply)
                await ConversationMemory.shared.record(user: raw, assistant: reply)
                finishLane(.apple, start: laneStart, raw: raw)
                presentJarvisReply(reply, raw: raw)
                return reply
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
                hud.present(.progress("Summoning Claude popover"))
                speak("Launching Claude popover.")
                await ClaudeQuickEntry.send("")
            case .prepPrompt(let useCase):
                await handlePrepPrompt(useCase)
            case .sendLastPromptToClaude:
                await handleSendLastPrompt()
            }
            finishLane(.reflex, start: laneStart, raw: raw)
            state = .idle
            Task { try? await Task.sleep(for: .seconds(2)); hud.hide() }
            return ""
        }
        
        // 6. Nothing matched — report why Jarvis couldn't act.
        let errorMessage: String
        if let err = agentError { errorMessage = err.localizedDescription }
        else if let availErr = JarvisAgent.availabilityError() { errorMessage = availErr }
        else { errorMessage = "Apple Intelligence is unavailable on this machine." }
        print("[JARVIS] Failed: \(errorMessage)")
        hud.present(.warning("Jarvis unavailable"))
        speak("Jarvis is unavailable. \(errorMessage)")
        finishLane(.failed, start: laneStart, raw: raw)
        state = .idle
        Task { try? await Task.sleep(for: .seconds(3.5)); hud.hide() }
        return errorMessage
    }

    /// Executes a Jarvis Brain memory hit. Kernel actions run the named reflex against
    /// the raw utterance (the reflex re-parses it and may decline); tool actions replay
    /// the captured arguments through the native registry, gated by the brain's
    /// allowlist. Nil or a throw means "fall through to the LLM" — never a dead end.
    private func runBrainAction(_ action: BrainAction, raw: String) async -> String? {
        switch action {
        case .kernel(let capability):
            return await Kernel.shared.runReflex(named: capability, intent: raw)
        case .tool(let name, let argsJson):
            guard JarvisBrain.directExecutionAllowlist.contains(name) else { return nil }
            do {
                return try await JarvisToolbox.callToolNatively(name: name, jsonArgs: argsJson)
            } catch {
                print("[BRAIN] Replay of learned tool '\(name)' failed (\(error.localizedDescription)); falling through to the model.")
                return nil
            }
        }
    }

    /// Presents a Jarvis reply: when the model asks a clarifying question (the `ASK:`
    /// convention), speak it and re-open the mic for the answer; otherwise show + speak the
    /// reply normally. Manages `state`/HUD lifecycle.
    @MainActor
    func presentJarvisReply(_ reply: String, raw: String) {
        if reply.hasPrefix(kClarificationPrefix) {
            let question = String(reply.dropFirst(kClarificationPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            print("[JARVIS] Clarifying question: \(question)")
            hud.present(.clarify(question))
            speak(question)
            pendingClarification = true
            state = .idle
            // Do NOT auto-reopen the mic here — doing so with a timer race overwrites
            // currentMode and permanently kills Jarvis for the session.
            // The user re-activates Jarvis (⌘⇧J) to give the answer; pendingClarification
            // routes that transcript to continueClarification instead of a fresh turn.
            // Safety timeout: if no answer arrives in 30 s, discard the pending state.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                guard self.pendingClarification else { return }
                self.pendingClarification = false
                self.hud.hide()
                print("[JARVIS] Clarification timed out — discarding pending state.")
            }
            return
        }
        if reply.isEmpty {
            hud.present(.success(Quips.done()), dismissAfter: 6)
        } else {
            // Full reply in the glass card; speak only the one-line headline.
            CommandEngine.lastResult = reply
            hud.present(.reply(reply))
            speak(shortSpoken(reply))
        }
        state = .idle
        Task { try? await Task.sleep(for: .seconds(2)); self.hud.hide() }
    }
    
    /// Continues the Jarvis session with the user's answer to a clarifying question, reusing
    /// the same multi-turn transcript so prior context is preserved.
    func continueClarification(answer: String, samples: [Float]) async {
        guard let coord = self.coordinator else {
            state = .idle; hud.hide(); return
        }
        state = .polishing
        hud.present(.thinking("Jarvis"), mode: .jarvis)
        do {
            let reply = Self.sanitizeReply(try await coord.handleTurn(userInput: answer, isFollowUp: true))
            print("[JARVIS] Clarification reply: '\(reply)'")
            DatasetLogger.shared.log(mode: "jarvis-clarify", app: lastActiveApp?.localizedName, rawTranscript: answer, response: reply, kind: "agent", samples: samples)
            TaskJournal.record(command: answer, reply: reply)
            presentJarvisReply(reply, raw: answer)
        } catch {
            print("[JARVIS] Clarification failed: \(error.localizedDescription)")
            hud.present(.warning("Jarvis unavailable"))
            speak("Jarvis is unavailable.")
            state = .idle
            Task { try? await Task.sleep(for: .seconds(3)); self.hud.hide() }
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
        if let coord = self.coordinator {
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
    
    /// Records which lane handled a command and how long (transcript-ready → action)
    /// it took, then logs a one-liner. The latency excludes recording/transcription so
    /// it isolates the lane's own "thinking" cost — the number to compare against Siri.
    func finishLane(_ lane: Lane, start: CFAbsoluteTime, raw: String) {
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[LANE] \(lane.rawValue) \(String(format: "%.0f", ms))ms — '\(raw.prefix(48))'")
        Task { await LaneStats.shared.record(lane: lane, ms: ms) }
        AppController.shared?.updateMemoryLedger()
    }
    
    /// Executes a matched zero-latency shortcut (native actions / system info report).
    func runZeroLatencyShortcut(_ shortcut: CommandEngine.ZeroLatencyShortcut) async {
        print("[JARVIS] Zero-latency shortcut: \(shortcut.hudMessage)")
        state = .polishing
        hud.present(.thinking(shortcut.hudMessage))
        
        let output: String
        if shortcut.command.hasPrefix("skill:") {
            let skillName = String(shortcut.command.dropFirst(6))
            output = await SkillStore.runEnabled(skillName)
        } else if shortcut.command.hasPrefix("native:") {
            let action = String(shortcut.command.dropFirst(7))
            output = await NativeActions.perform(action)
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
        
        hud.present(.success(shortcut.hudMessage))
        state = .idle
        Task { try? await Task.sleep(for: .seconds(1.5)); hud.hide() }
    }
    
    func writeNoteFile(filename: String, content: String) {
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
    
    func getBestEnglishVoice() -> AVSpeechSynthesisVoice? {
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
    
    func speakWithSystemSynthesizer(_ text: String) {
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
    func handleIncomingCommandText(_ text: String) async {
        print("[APP] Received external command text: '\(text)'")
        state = .transcribing
        hud.present(.thinking("Processing command"))
        
        let context = ContextDetector.current()
        let output = await CommandEngine.process(text, context: context, selection: nil)
        let processedText = output.text
        
        // External commands (sotto:// URL scheme) run through the native Apple agent.
        if !processedText.isEmpty,
           SettingsController.apiProvider.lowercased() == "apple",
           JarvisAgent.isAvailable() {
            self.state = .polishing
            self.hud.present(.thinking("Jarvis"), mode: .jarvis)
            do {
                let reply: String
                if let coord = self.coordinator {
                    reply = Self.sanitizeReply(try await coord.handleTurn(userInput: processedText))
                } else {
                    reply = "Jarvis is still starting. Please try again in a moment."
                }
                DatasetLogger.shared.log(mode: "jarvis-url", app: self.lastActiveApp?.localizedName, rawTranscript: processedText, response: reply, kind: "agent", samples: nil)
                TaskJournal.record(command: processedText, reply: reply)
                if reply.isEmpty {
                    self.hud.present(.success("Done"))
                } else {
                    self.hud.present(.reply(reply))
                    self.speak(reply)
                }
                self.state = .idle
                Task { try? await Task.sleep(for: .seconds(2)); self.hud.hide() }
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
                try? await Task.sleep(for: .milliseconds(150))
            }
            
            if output.delayBeforeInject > 0 {
                try? await Task.sleep(for: .seconds(output.delayBeforeInject))
            }
            
            if let shortcut = output.searchShortcut {
                await self.injector.pressSearchShortcut(shortcut, targetPID: self.lastActiveApp?.processIdentifier)
                try? await Task.sleep(for: .milliseconds(300))
            }
            
            if !processedText.isEmpty || output.fileURL != nil {
                await self.injector.inject(processedText, fileURL: output.fileURL, targetPID: self.lastActiveApp?.processIdentifier)
            }
            
            if output.pressReturnAfter {
                try? await Task.sleep(for: .milliseconds(350))
                await self.injector.pressReturn(targetPID: self.lastActiveApp?.processIdentifier)
            }
            
            self.statusBar.lastTranscript = processedText
            self.hud.present(.success("Done"))
            self.state = .idle
            Task {
                try? await Task.sleep(for: .seconds(1.5))
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
    func handlePrepPrompt(_ useCase: PromptUseCase) async {
        var screenText: String? = nil
        if useCase.needsScreenContext {
            self.hud.present(.progress("Reading your screen"))
            screenText = await CommandEngine.ocrScreen()
        }
        
        let prepped = PromptBuilder.build(useCase, screenText: screenText)
        PromptStore.save(prepped)
        
        self.hud.present(.success("Prompt ready", detail: "Review before sending"))
        self.speak("Prompt ready for review.")
        
        self.promptReview.show(prompt: prepped) { [weak self] editedText in
            guard let self else { return }
            Task { @MainActor in
                self.hud.present(.progress("Sending to Claude popover"))
                self.speak("Sending prompt to Claude popover.")
                await ClaudeQuickEntry.send(editedText)
                self.hud.present(.success("Sent to Claude popover"))
            }
        }
    }
    
    /// Sends the most recently prepared prompt to Claude (batch step 2).
    @MainActor
    func handleSendLastPrompt() async {
        guard let last = PromptStore.loadLast() else {
            self.hud.present(.warning("No prepared prompt saved"))
            self.speak("No prompt saved. Please prep first.")
            return
        }
        self.hud.present(.progress("Sending to Claude popover"))
        self.speak("Sending prompt to Claude popover.")
        await ClaudeQuickEntry.send(last.assembledText)
        self.hud.present(.success("Sent to Claude popover"))
    }
    
    /// If the utterance is a weather ask, returns the city to look up (named city, or the
    /// saved home city). Lets us answer weather deterministically instead of trusting the
    /// small model, which sometimes hallucinates a "permission denied" for a keyless API.
    static func weatherCity(in raw: String) -> String? {
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
        let home = SettingsController.homeCity
        return home.isEmpty ? nil : home
    }
    
    /// Strip chat-template role tokens the on-device model sometimes leaks (e.g. a leading
    /// "model\n" or "assistant ") so they never reach the screen or the voice.
    static func sanitizeReply(_ s: String) -> String {
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
    func shortSpoken(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let clause = firstLine.split(separator: ",", maxSplits: 1).first.map(String.init) ?? firstLine
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 70 ? trimmed : String(trimmed.prefix(70))
    }
    
    /// If the utterance opens with the "Hey Jarvis" wake phrase (robust to the ASR mishearing
    /// it as one garbled word, e.g. "Hejarvis"), returns the command with the wake words
    /// stripped; otherwise nil. Lets the user summon Jarvis from any mode.
    ///
    /// Thin wrapper over `BridgeDecision.classify` (the single source of truth in SottoCore) so
    /// Jarvis-mode wake stripping and the dictation→Jarvis bridge can never drift apart.
    static func jarvisWakeCommand(in raw: String) -> String? {
        BridgeDecision.classify(raw).command
    }
}
