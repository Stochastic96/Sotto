import Foundation
import os
@preconcurrency import Speech
import AVFoundation

// MARK: - TranscriptionBackend Protocol

/// A single speech-recognition implementation. The app ships one backend
/// (`NativeDictationBackend`); the protocol exists so the legacy fallback and any
/// future engine can be swapped in without touching `Transcriber`.
protocol TranscriptionBackend: Sendable {
    func prepare() async throws
    /// `samples` must be 16 kHz mono Float32.
    func transcribe(_ samples: [Float]) async throws -> String
    /// Begin a live streaming pass fed by `audio`. Returns a stream of display-only
    /// partial transcripts, or nil when this backend can't stream (caller stays on batch).
    /// The caller MUST finish the `audio` stream before calling `finishStreaming()`.
    func startStreaming(feeding audio: AsyncStream<SendableAudioBuffer>) async throws -> AsyncStream<String>?
    /// Finalize the active streaming pass and return its transcript.
    /// nil → no active pass, or it failed/was empty; caller falls back to batch transcribe.
    func finishStreaming() async -> String?
    /// Tear down the active streaming pass without using its result.
    func cancelStreaming() async
}

extension TranscriptionBackend {
    func startStreaming(feeding audio: AsyncStream<SendableAudioBuffer>) async throws -> AsyncStream<String>? { nil }
    func finishStreaming() async -> String? { nil }
    func cancelStreaming() async {}
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
    // 16 kHz mono — the fixed capture format AudioRecorder produces. `prepareToAnalyze(in:)`
    // tells the analyzer to expect buffers in this exact format so no extra
    // AnalyzerInputConverter plumbing is needed.
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    // The format the analyzer's module actually accepts. The Speech framework does NO audio
    // conversion and preconditions on the module's required sample type (DictationTranscriber
    // wants 16-bit Int PCM, not the recorder's Float32), so every buffer is converted to this
    // before it's wrapped in an AnalyzerInput. Resolved via bestAvailableAudioFormat.
    private var analyzerFormat: AVAudioFormat?
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

            // Ask the module which format it can analyze; fall back to the capture format
            // only if the query fails (assets missing) — feeding an unsupported format trips
            // a "sample data must be 16-bit signed integers" precondition inside the analyzer.
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) ?? Self.format
            let a = SpeechAnalyzer(
                modules: [t],
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            try await a.prepareToAnalyze(in: format)

            self.transcriber = t
            self.analyzer = a
            self.analyzerFormat = format
            self.useLegacy = false
            print("[TRANSCRIBER] Native DictationTranscriber ready (\(resolved.identifier), format: \(format.commonFormat.rawValue)@\(Int(format.sampleRate))Hz).")
        } catch {
            print("[TRANSCRIBER] Native dictation unavailable (\(error.localizedDescription)); falling back to legacy Apple Speech.")
            useLegacy = true
            try await legacyFallback.prepare()
        }
     }

    // MARK: - Format conversion

    /// Convert `buffer` to `format` using a caller-supplied converter (reused across a
    /// streaming session to avoid per-buffer converter allocation). Returns nil on error.
    fileprivate static func convertBuffer(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }

    /// One-shot convert (builds its own converter). Returns the input unchanged when it
    /// already matches `format`. Used by the batch path where conversion happens once.
    fileprivate static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        return convertBuffer(buffer, using: converter, to: format)
    }

    // MARK: - Streaming (live partials + final-transcript reuse)

    /// One live streaming pass. `transcriber.results` tolerates only ONE consumer, so the
    /// backend owns the session and tears it down before any batch `transcribe()` runs.
    final class StreamingSession: @unchecked Sendable {
        let partials: AsyncStream<String>
        private let analysisTask: Task<Void, Never>
        private let collectorTask: Task<String, Never>
        private let finalize: @Sendable () async throws -> Void
        private let lock = NSLock()
        private var terminated = false

        init(partials: AsyncStream<String>,
             analysisTask: Task<Void, Never>,
             collectorTask: Task<String, Never>,
             finalize: @escaping @Sendable () async throws -> Void) {
            self.partials = partials
            self.analysisTask = analysisTask
            self.collectorTask = collectorTask
            self.finalize = finalize
        }

        /// Drain the analyzer, finalize, and return the accumulated transcript.
        /// The audio input stream must already be finished. nil → failed or empty;
        /// the caller should batch-transcribe the recorded samples instead.
        func finish() async -> String? {
            guard beginTerminate() else { return nil }
            do {
                try await withTimeout(seconds: 10, errorDomain: "Transcriber",
                                      errorDescription: "Streaming finalize timed out") { [analysisTask, finalize] in
                    await analysisTask.value
                    try await finalize()
                }
            } catch {
                print("[STREAM-ASR] Finalize failed (\(error.localizedDescription)); discarding streaming result.")
                collectorTask.cancel()
                _ = await collectorTask.value
                return nil
            }
            // results should end after finalize; the backstop covers the known hang case
            // (same pattern as the batch path).
            let backstop = Task { try? await Task.sleep(for: .seconds(2)); collectorTask.cancel() }
            let text = await collectorTask.value
            backstop.cancel()
            return text.isEmpty ? nil : text
        }

        /// Tear down without using the result (batch path takes over, or an aborted press).
        func cancel() {
            guard beginTerminate() else { return }
            collectorTask.cancel()
            analysisTask.cancel()
        }

        private func beginTerminate() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if terminated { return false }
            terminated = true
            return true
        }
    }

    private var activeStreamingSession: StreamingSession?

    func startStreaming(feeding audio: AsyncStream<SendableAudioBuffer>) async throws -> AsyncStream<String>? {
        // Never two sessions: a stale one (e.g. from an aborted short-tap) dies first.
        activeStreamingSession?.cancel()
        activeStreamingSession = nil

        if transcriber == nil {
            try await prepare()
        }
        guard !useLegacy, let transcriber, let analyzer else {
            return nil
        }

        let context = AnalysisContext()
        let vocab = Self.contextualVocabulary()
        if !vocab.isEmpty { context.contextualStrings[.general] = vocab }
        try await analyzer.setContext(context)

        let (partialStream, partialContinuation) = AsyncStream<String>.makeStream()

        // The single consumer of transcriber.results: accumulates final segments and
        // yields display partials (finals so far + the current volatile hypothesis).
        let collectorTask = Task<String, Never> {
            var finalText = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalText += text
                        partialContinuation.yield(finalText)
                    } else if !text.isEmpty {
                        partialContinuation.yield(finalText + text)
                    }
                }
            } catch {
                // CancellationError / analyzer error — keep what we accumulated.
            }
            partialContinuation.finish()
            return finalText
        }

        let analysisTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(AnalyzerInputStream(audio, convertingTo: self.analyzerFormat ?? Self.format))
            } catch {
                print("[STREAM-ASR] Analysis error: \(error.localizedDescription)")
            }
        }

        activeStreamingSession = StreamingSession(
            partials: partialStream,
            analysisTask: analysisTask,
            collectorTask: collectorTask,
            finalize: { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        )
        return partialStream
    }

    func finishStreaming() async -> String? {
        guard let session = activeStreamingSession else { return nil }
        activeStreamingSession = nil
        guard let text = await session.finish() else {
            // After a failed/hung finalize the cached analyzer's state is unknown —
            // rebuild on the next press instead of risking a wedged instance. (Also hit
            // on an empty transcript; the rare rebuild there is a fair price for safety.)
            self.transcriber = nil
            self.analyzer = nil
            return nil
        }
        return text
    }

    func cancelStreaming() async {
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        // A leftover streaming session must die first — transcriber.results tolerates
        // only one consumer, and a zombie collector would race this batch pass for text.
        await cancelStreaming()

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

        // Convert to the module's supported format (see analyzerFormat) — the analyzer does
        // no conversion and preconditions on the sample type otherwise.
        guard let analyzerBuffer = Self.convert(buffer, to: self.analyzerFormat ?? Self.format) else {
            throw Transcriber.TranscriberError.notReady
        }

        do {
            try await analyzer.setContext(context)

            let input = AnalyzerInput(buffer: analyzerBuffer)
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

            let text = try await withTimeout(seconds: timeoutSeconds, errorDomain: "Transcriber", errorDescription: "Modern transcription timed out") {
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

/// Drives dictation through the native Apple `NativeDictationBackend` (SpeechAnalyzer),
/// which self-heals to `LegacyAppleSpeechBackend` if the modern stack can't prepare.
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
    // Cached so repeated dictation presses reuse the warm, `.lingering`-retained
    // SpeechAnalyzer/DictationTranscriber instead of re-installing the asset each time.
    private var nativeDictationBackend: NativeDictationBackend?

    func prepare() async throws {
        print("[TRANSCRIBER] Preparing native Apple dictation engine")
        let backend = nativeDictationBackend ?? NativeDictationBackend()
        nativeDictationBackend = backend
        try await backend.prepare()
        activeBackend = backend
    }

    /// `samples` must be 16 kHz mono Float32.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let activeBackend else { throw TranscriberError.notReady }
        return try await activeBackend.transcribe(samples)
    }

    /// Begin a live streaming pass. Returns display partials, or nil when the active
    /// backend can't stream — the caller simply stays on the batch path.
    func startStreaming(feeding audio: AsyncStream<SendableAudioBuffer>) async throws -> AsyncStream<String>? {
        guard let activeBackend else { return nil }
        return try await activeBackend.startStreaming(feeding: audio)
    }

    /// Final transcript of the active streaming pass, or nil (→ batch-transcribe instead).
    func finishStreaming() async -> String? {
        await activeBackend?.finishStreaming()
    }

    func cancelStreaming() async {
        await activeBackend?.cancelStreaming()
    }
}

// MARK: - AnalyzerInputStream

struct AnalyzerInputStream: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput

    private let base: AsyncStream<SendableAudioBuffer>
    private let targetFormat: AVAudioFormat

    init(_ base: AsyncStream<SendableAudioBuffer>, convertingTo targetFormat: AVAudioFormat) {
        self.base = base
        self.targetFormat = targetFormat
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var baseIterator: AsyncStream<SendableAudioBuffer>.AsyncIterator
        let targetFormat: AVAudioFormat
        // Built lazily from the first buffer's format and reused — the analyzer requires its
        // module's format and does no conversion itself.
        var converter: AVAudioConverter?

        mutating func next() async -> AnalyzerInput? {
            guard let wrapper = await baseIterator.next() else { return nil }
            let buffer = wrapper.buffer
            if buffer.format == targetFormat {
                return AnalyzerInput(buffer: buffer)
            }
            if converter == nil {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter,
                  let converted = NativeDictationBackend.convertBuffer(buffer, using: converter, to: targetFormat) else {
                // Best effort: feed the original rather than dropping audio silently.
                return AnalyzerInput(buffer: buffer)
            }
            return AnalyzerInput(buffer: converted)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(baseIterator: base.makeAsyncIterator(), targetFormat: targetFormat, converter: nil)
    }
}
