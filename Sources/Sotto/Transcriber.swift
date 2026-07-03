import Foundation
import FluidAudio
import os
@preconcurrency import Speech
import AVFoundation

// MARK: - TranscriptionBackend Protocol

/// A single speech-recognition implementation.
///
/// To add a new engine: create a type conforming to `TranscriptionBackend` and
/// return an instance from `Transcriber.makeBackend()`. No other changes needed.
protocol TranscriptionBackend: Sendable {
    func prepare() async throws
    /// `samples` must be 16 kHz mono Float32.
    func transcribe(_ samples: [Float]) async throws -> String
}

// MARK: - Parakeet (FluidAudio / ANE, fully offline)

// Only ever touched serially through the owning Transcriber actor.
private final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    private var manager: AsrManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad()
        manager = AsrManager(config: .default, models: models)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw Transcriber.TranscriberError.notReady }
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }
}

// MARK: - Apple Native Dictation (SpeechAnalyzer / DictationTranscriber, macOS 26+)

/// Native on-device dictation via the modern `SpeechAnalyzer` + `DictationTranscriber`
/// stack — the same engine class Apple's own Dictation and Notes use. Replaces the
/// legacy `SFSpeechRecognizer` path: no delegate-callback race (the bug the old 8s
/// watchdog in `LegacyAppleSpeechBackend` existed to paper over), contextual-vocabulary
/// injection at the ASR layer instead of only post-hoc in the polish prompt, and an
/// explicit on-device asset install step instead of an implicit one.
///
/// Falls back to `LegacyAppleSpeechBackend` if the modern path fails to prepare or
/// transcribe (e.g. asset install fails without network) — this is the user's daily
/// dictation driver, so a brand-new OS-beta API gets a safety net rather than a hard
/// failure.
private final class NativeDictationBackend: TranscriptionBackend, @unchecked Sendable {
    // 16 kHz mono — the same fixed capture format AudioRecorder already produces for
    // Parakeet. `prepareToAnalyze(in:)` tells the analyzer to expect buffers in this
    // exact format so no extra AnalyzerInputConverter plumbing is needed.
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private let legacyFallback = LegacyAppleSpeechBackend()
    private var useLegacy = false

    func prepare() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { s in
                    continuation.resume(returning: s == .authorized)
                }
            }
            if !authorized { throw Transcriber.TranscriberError.permissionDenied }
        } else if status != .authorized {
            throw Transcriber.TranscriberError.permissionDenied
        }

        guard transcriber == nil else { return }

        do {
            let resolved = await DictationTranscriber.supportedLocale(equivalentTo: .current)
                ?? Locale(identifier: "en-US")
            let t = DictationTranscriber(locale: resolved, preset: .longDictation)

            if await AssetInventory.status(forModules: [t]) != .installed {
                print("[TRANSCRIBER] Installing on-device dictation model for \(resolved.identifier)…")
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                    try await request.downloadAndInstall()
                }
            }

            let a = SpeechAnalyzer(
                modules: [t],
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            try await a.prepareToAnalyze(in: Self.format)

            self.transcriber = t
            self.analyzer = a
            self.useLegacy = false
            print("[TRANSCRIBER] Native DictationTranscriber ready (\(resolved.identifier)).")
        } catch {
            print("[TRANSCRIBER] Native dictation unavailable (\(error.localizedDescription)); falling back to legacy Apple Speech.")
            useLegacy = true
            try await legacyFallback.prepare()
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        // `prepare()` only runs once at launch (AppController.loadModel), not before every
        // press — so if a prior transcribe() invalidated the cached analyzer after a
        // failure, rebuild it here rather than staying permanently degraded to legacy.
        if !useLegacy, transcriber == nil {
            try? await prepare()
        }
        guard !useLegacy, let transcriber, let analyzer else {
            return try await legacyFallback.transcribe(samples)
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw Transcriber.TranscriberError.notReady
        }
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                channel[0].update(from: base, count: samples.count)
            }
        }

        // Contextual vocabulary at the ASR layer — correct spellings land in the
        // transcript itself instead of relying on the polish prompt to fix them after.
        let context = AnalysisContext()
        let vocab = Self.contextualVocabulary()
        if !vocab.isEmpty { context.contextualStrings[.general] = vocab }

        do {
            try await analyzer.setContext(context)

            let input = AnalyzerInput(buffer: buffer)
            let stream = AsyncStream<AnalyzerInput> { continuation in
                continuation.yield(input)
                continuation.finish()
            }

            // Run the results collection in a separate task so we can cancel its infinite stream
            // once analysis of the input sequence is complete.
            let transcriptionTask = Task {
                var finalText = ""
                do {
                    for try await result in transcriber.results where result.isFinal {
                        finalText += String(result.text.characters)
                    }
                } catch {
                    // Catch CancellationError and return the partial we accumulated
                }
                return finalText
            }
            defer {
                transcriptionTask.cancel()
            }

            let audioDuration = Double(samples.count) / 16000.0
            let timeoutSeconds = max(8.0, audioDuration * 0.5)
            print("[TRANSCRIBER] Native dictation: transcribing \(samples.count) samples (~\(String(format: "%.1f", audioDuration))s audio). Timeout set to \(String(format: "%.1f", timeoutSeconds))s.")

            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    _ = try await analyzer.analyzeSequence(stream)
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    
                    // Start a 2-second backstop task to cancel transcription if it hangs
                    let backstopTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled {
                            transcriptionTask.cancel()
                        }
                    }
                    
                    let text = await transcriptionTask.value
                    backstopTask.cancel()
                    return text
                }
                
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw NSError(domain: "Transcriber", code: -99, userInfo: [NSLocalizedDescriptionKey: "Modern transcription timed out"])
                }
                
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            return text
        } catch {
            print("[TRANSCRIBER] Native dictation transcribe failed/timed out (\(error.localizedDescription)); falling back to legacy Apple Speech for this utterance.")
            // Don't set useLegacy = true here — that's reserved for a structurally
            // unavailable modern path (permission/asset failure in prepare()). A transcribe-
            // level failure gets a clean rebuild attempt on the next press instead of
            // permanently degrading every future dictation to the legacy path.
            self.transcriber = nil
            self.analyzer = nil
            try? await legacyFallback.prepare()
            return try await legacyFallback.transcribe(samples)
        }
    }

    /// Custom vocabulary (Settings) + learned jargon, same sources `SottoIntelligence`
    /// injects into the polish prompt — fed here too so ASR gets them right at the source.
    private static func contextualVocabulary() -> [String] {
        let custom = SettingsController.customVocabulary
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let learned = UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? []
        return Array(Set(custom + learned)).prefix(100).map { $0 }
    }
}

// MARK: - Legacy Apple Speech (SFSpeechRecognizer) — fallback only

/// Kept as the safety net `NativeDictationBackend` falls back to, and to keep
/// `LegacyAppleSpeechBackend` buildable standalone if the modern stack ever needs
/// bypassing entirely. Not user-selectable on its own.
private struct LegacyAppleSpeechBackend: TranscriptionBackend {
    func prepare() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status != .authorized else { return }
        if status == .notDetermined {
            let authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { s in
                    continuation.resume(returning: s == .authorized)
                }
            }
            if !authorized { throw Transcriber.TranscriberError.permissionDenied }
        } else {
            throw Transcriber.TranscriberError.permissionDenied
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw Transcriber.TranscriberError.speechRecognizerNotAvailable
        }
        
        let audioDuration = Double(samples.count) / 16000.0
        let timeoutSeconds = max(8.0, audioDuration * 0.5)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "Transcriber", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM buffer for Speech Recognition"])
        }
        buffer.frameLength = buffer.frameCapacity
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].initialize(from: ptr.baseAddress!, count: samples.count)
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.append(buffer)
        request.endAudio()

        // SFSpeechRecognizer's on-device recognizer can — under memory pressure on
        // an 8 GB M1 — deliver partial results and then NEVER deliver `isFinal` and
        // NEVER an error. The old code resumed the continuation only on `.isFinal`
        // or error, so that case hung this `await` forever and wedged the whole app
        // at `.transcribing` (every later hotkey press → "Still transcribing…").
        // Fix: keep the latest partial, add an 8s safety timeout, and resume with
        // the best partial we have. A genuine "no speech" outcome resolves to "" so
        // the pipeline just returns to idle instead of throwing a scary error.
        // `SFSpeechRecognitionTask` is not Sendable; box it so the timeout closure
        // can cancel it without tripping concurrency warnings.
        final class TaskBox: @unchecked Sendable { var task: SFSpeechRecognitionTask? }
        struct SpeechState { var finished = false; var partial = "" }
        let box = TaskBox()
        let state = OSAllocatedUnfairLock(initialState: SpeechState())
        return try await withCheckedThrowingContinuation { continuation in
            box.task = recognizer.recognitionTask(with: request) { result, error in
                // withLock owns both fields; returning String? avoids capturing a var.
                let resumeText: String? = state.withLock { s in
                    guard !s.finished else { return nil }
                    if let result {
                        s.partial = result.bestTranscription.formattedString
                        if result.isFinal { s.finished = true; return s.partial }
                    }
                    if error != nil {
                        s.finished = true
                        // Prefer any partial we captured; treat "no speech
                        // detected" as an empty (silent) result, not a hard failure.
                        return s.partial
                    }
                    return nil
                }
                if let text = resumeText { continuation.resume(returning: text) }
            }

            Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                let resumeText: String? = state.withLock { s in
                    guard !s.finished else { return nil }
                    s.finished = true
                    return s.partial
                }
                if let text = resumeText {
                    box.task?.cancel()
                    print("[TRANSCRIBER] Apple Speech timed out after \(String(format: "%.1f", timeoutSeconds))s; returning best partial (\(text.count) chars).")
                    continuation.resume(returning: text)
                }
            }
        }
    }
}

// MARK: - Transcriber

/// Routes transcription to the active backend selected in SettingsController.
/// Adding a new engine requires only a new `TranscriptionBackend` conformance
/// and a case in `makeBackend()` — `prepare()` and `transcribe()` stay unchanged.
actor Transcriber {
    enum TranscriberError: LocalizedError {
        case notReady
        case speechRecognizerNotAvailable
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Speech model is not loaded yet."
            case .speechRecognizerNotAvailable:
                return "Apple Speech Recognizer is not available for your system or locale."
            case .permissionDenied:
                return "Speech Recognition permission not granted by system. Please enable it in Settings > Privacy & Security > Speech Recognition."
            }
        }
    }

    private var activeBackend: (any TranscriptionBackend)?
    // Cached so switching back to .offlineAI doesn't re-download the model.
    private var parakeetBackend: ParakeetBackend?
    // Cached so repeated dictation presses reuse the warm, `.lingering`-retained
    // SpeechAnalyzer/DictationTranscriber instead of re-installing the asset each time.
    private var nativeDictationBackend: NativeDictationBackend?

    func prepare() async throws {
        let setting = SettingsController.transcriptionEngine
        print("[TRANSCRIBER] Preparing engine: \(setting.rawValue)")
        let backend = makeBackend(for: setting)
        try await backend.prepare()
        activeBackend = backend
    }

    /// `samples` must be 16 kHz mono Float32.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let activeBackend else { throw TranscriberError.notReady }
        return try await activeBackend.transcribe(samples)
    }

    private func makeBackend(for setting: TranscriptionEngine) -> any TranscriptionBackend {
        switch setting {
        case .offlineAI:
            let backend = parakeetBackend ?? ParakeetBackend()
            parakeetBackend = backend
            nativeDictationBackend = nil  // release the lingering model when switching away
            return backend
        case .appleSpeech:
            parakeetBackend = nil  // release model weights when switching away
            let backend = nativeDictationBackend ?? NativeDictationBackend()
            nativeDictationBackend = backend
            return backend
        }
    }
}
