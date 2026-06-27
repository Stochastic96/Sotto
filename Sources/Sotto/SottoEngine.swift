import AppKit
import AVFoundation
import Speech
import SottoCore

// MARK: - SottoEngine
//
// Owns the microphone, transcription, routing, and tool execution.
// Consumes EventBus trigger events; emits processingStarted / transcribed / engineResult / engineError.
// The single AVAudioEngine lives here — wake-word and recording share it time-slice, never concurrently.

@MainActor
final class SottoEngine {
    static let shared = SottoEngine()

    // MARK: - Sub-components (all owned here)
    private let recorder   = AudioRecorder()
    private let transcriber = Transcriber()
    private var intelligence: SottoIntelligence?
    private var coordinator: AnyObject?    // CoordinatorAgent (macOS 26 only)

    var lastActiveApp: NSRunningApplication?

    // MARK: - Lifecycle

    func preload() async {
        if #available(macOS 26.0, *) {
            coordinator = CoordinatorAgent()
        }
        let intel = SottoIntelligence { _ in }
        intelligence = intel
        await intel.preload()
    }

    func start() {
        Task { await listenForTriggers() }
    }

    // MARK: - EventBus consumer

    private var currentMode: EventBus.TriggerMode = .dictation
    private var isRecording = false

    private func listenForTriggers() async {
        for await event in await EventBus.shared.makeStream() {
            switch event {
            case .hotkeyPressed(let mode):
                currentMode = mode
                await beginRecording(mode: mode)
            case .hotkeyReleased:
                await endRecording()
            case .wakeWordDetected:
                currentMode = .assistant
                await beginRecording(mode: .assistant)
            case .externalCommand(let text):
                await processText(text, mode: .assistant, samples: [])
            default: break
            }
        }
    }

    // MARK: - Recording

    private func beginRecording(mode: EventBus.TriggerMode) async {
        guard !isRecording, AXIsProcessTrusted() else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            await EventBus.shared.emit(.engineError("Microphone access denied — grant it in System Settings → Privacy → Microphone"))
            return
        }
        // Capture frontmost app before we steal focus
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = front
        }
        do {
            try recorder.start()
            isRecording = true
            await EventBus.shared.emit(.processingStarted(mode: mode))
        } catch {
            await EventBus.shared.emit(.engineError("Mic error: \(error.localizedDescription)"))
        }
    }

    private func endRecording() async {
        guard isRecording else { return }
        isRecording = false
        let samples = recorder.stop()
        guard samples.count > 4800 else { return }   // < 0.3s — accidental tap

        do {
            var raw = try await transcriber.transcribe(samples)
            raw = VocabCorrector.apply(to: raw)
            raw = stripWakePrefix(raw)
            guard !raw.isEmpty else { return }
            await EventBus.shared.emit(.transcribed(text: raw))
            await processText(raw, mode: currentMode, samples: samples)
        } catch {
            await EventBus.shared.emit(.engineError("Transcription failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Routing

    private func processText(_ text: String, mode: EventBus.TriggerMode, samples: [Float]) async {
        let start = CFAbsoluteTimeGetCurrent()

        if mode == .dictation {
            await runDictation(text, samples: samples, start: start)
        } else {
            await runAssistant(text, samples: samples, start: start)
        }
    }

    // MARK: - Dictation path

    private func runDictation(_ raw: String, samples: [Float], start: CFAbsoluteTime) async {
        var text = raw
        let wordCount = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count

        // Polish with Apple Intelligence if long enough
        if wordCount >= 6, let q = intelligence {
            if let polished = try? await q.refine(raw, context: ContextDetector.current(), history: []),
               isAcceptablePolish(original: raw, polished: polished) {
                text = polished
            }
        }

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let result = EventBus.EngineResult(
            mode: .dictation, transcript: raw, reply: "",
            injectText: text, tier: "reflex",
            toolsUsed: [], latencyMs: ms
        )

        // Inject into the last active app
        await SottoOutput.shared.inject(text, targetPID: lastActiveApp?.processIdentifier)
        await EventBus.shared.emit(.engineResult(result))
        DatasetLogger.shared.log(mode: "dictation", app: lastActiveApp?.localizedName,
                                 rawTranscript: raw, response: text, kind: "polish", samples: samples)
    }

    // MARK: - Assistant / Jarvis path

    private func runAssistant(_ raw: String, samples: [Float], start: CFAbsoluteTime) async {
        if await CooperativeWorkflowManager.shared.handleResponse(raw) {
            return
        }

        // Tier 0: zero-latency reflexes
        if let shortcut = CommandEngine.checkZeroLatencyShortcut(for: raw) {
            let action = shortcut.command
            var reply = shortcut.hudMessage
            if action.hasPrefix("skill:") {
                reply = SkillStore.runEnabled(String(action.dropFirst(6)))
            } else if action.hasPrefix("native:") {
                reply = await NativeActions.perform(String(action.dropFirst(7)))
            } else {
                reply = CommandEngine.runCommandNatively(action)
            }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let result = EventBus.EngineResult(
                mode: .assistant, transcript: raw, reply: reply,
                injectText: nil, tier: "reflex", toolsUsed: [], latencyMs: ms
            )
            await EventBus.shared.emit(.engineResult(result))
            return
        }

        // Tier 1: Kernel reflexes (open app, web search, Spotify)
        if let reply = await Kernel.shared.dispatchCompound(raw) {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let result = EventBus.EngineResult(
                mode: .assistant, transcript: raw, reply: reply,
                injectText: nil, tier: "reflex", toolsUsed: [], latencyMs: ms
            )
            await EventBus.shared.emit(.engineResult(result))
            return
        }

        // Tier 2a: Mission orchestrator for multi-step / big tasks
        if #available(macOS 26.0, *), isMission(raw) {
            Task { await MissionOrchestrator.shared.run(goal: raw) }
            return
        }

        // Tier 2b: Foundation Models agent (macOS 26+)
        if #available(macOS 26.0, *), let coord = coordinator as? CoordinatorAgent {
            do {
                let reply = AppController.sanitizeReply(try await coord.handleTurn(userInput: raw))
                let ms    = (CFAbsoluteTimeGetCurrent() - start) * 1000
                let result = EventBus.EngineResult(
                    mode: .assistant, transcript: raw, reply: reply,
                    injectText: nil, tier: "apple", toolsUsed: [], latencyMs: ms
                )
                TaskJournal.record(command: raw, reply: reply)
                await ConversationMemory.shared.record(user: raw, assistant: reply)
                DatasetLogger.shared.log(mode: "jarvis-apple", app: lastActiveApp?.localizedName,
                                         rawTranscript: raw, response: reply, kind: "agent", samples: samples)
                await EventBus.shared.emit(.engineResult(result))
                return
            } catch {
                print("[ENGINE] Agent failed: \(error.localizedDescription)")
            }
        }

        await EventBus.shared.emit(.engineError(JarvisAgent.availabilityError() ?? "Apple Intelligence unavailable"))
    }

    // MARK: - Helpers

    private func isAcceptablePolish(original: String, polished: String) -> Bool {
        guard !polished.isEmpty else { return false }
        let oW = original.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        let pW = polished.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        guard oW >= 3 else { return false }
        return Double(pW) <= Double(oW) * 2.2 && Double(pW) >= Double(oW) * 0.5
    }

    // A "mission" is a compound goal with connectives: "and", "then", "also", "after that"
    // or explicit multi-step keywords. Single commands stay on the fast path.
    private func isMission(_ text: String) -> Bool {
        let lower = text.lowercased()
        let connectives = [" and then ", " and also ", " after that ", " then ", " also "]
        if connectives.contains(where: { lower.contains($0) }) { return true }
        let missionKeywords = ["for all", "for every", "all my", "bulk", "batch",
                               "clean up", "organise", "organize and", "read and", "summarise and",
                               "summarize and", "find and", "check and"]
        return missionKeywords.contains(where: { lower.contains($0) })
    }

    private func stripWakePrefix(_ raw: String) -> String {
        let words = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return raw }
        func isWake(_ w: String) -> Bool {
            let t = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            return t == "jarvis" || t.hasSuffix("jarvis") || t == "sotto"
        }
        var drop = 0
        if words[0].lowercased() == "hey", words.count > 1, isWake(words[1]) { drop = 2 }
        else if isWake(words[0]) { drop = 1 }
        guard drop > 0 else { return raw }
        return words.dropFirst(drop).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
