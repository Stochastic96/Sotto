import Foundation
import os
import Synchronization
@preconcurrency import Speech
import AVFoundation

// MARK: - TranscriptionBackend Protocol

/// A single speech-recognition implementation. The app ships one backend
/// (`NativeDictationBackend`); the protocol exists so a future engine can be swapped in
/// without touching `Transcriber`.
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
/// stack — the same engine class Apple's own Dictation and Notes use. This is the only
/// transcription engine: contextual-vocabulary injection happens at the ASR layer (not
/// just post-hoc in the polish prompt), with an explicit on-device asset install step.
///
/// If the modern path can't prepare or transcribe (e.g. asset install fails without
/// network), the error propagates to the caller — `AppController.endRecording` surfaces
/// it as an `.error` state and schedules recovery. There is no legacy fallback engine.
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
            print("[TRANSCRIBER] Native DictationTranscriber ready (\(resolved.identifier), format: \(format.commonFormat.rawValue)@\(Int(format.sampleRate))Hz).")
        } catch {
            print("[TRANSCRIBER] Native dictation failed to prepare (\(error.localizedDescription)).")
            throw error
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
        private let terminated = Mutex(false)

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
            terminated.withLock { alreadyTerminated in
                if alreadyTerminated { return false }
                alreadyTerminated = true
                return true
            }
        }
    }

    private var activeStreamingSession: StreamingSession?

    /// Whether a live streaming pass is in flight — checked by `Transcriber.unload()`
    /// so memory-pressure eviction never tears the backend out from under a dictation
    /// press that is still recording or finalizing.
    var isStreaming: Bool { activeStreamingSession != nil }

    func startStreaming(feeding audio: AsyncStream<SendableAudioBuffer>) async throws -> AsyncStream<String>? {
        // Never two sessions: a stale one (e.g. from an aborted short-tap) dies first.
        activeStreamingSession?.cancel()
        activeStreamingSession = nil

        if transcriber == nil {
            try await prepare()
        }
        guard let transcriber, let analyzer else {
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
        // failure, rebuild it here rather than staying permanently in a notReady state.
        if transcriber == nil {
            try await prepare()
        }
        guard let transcriber, let analyzer else {
            throw Transcriber.TranscriberError.notReady
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
            print("[TRANSCRIBER] Native dictation transcribe failed/timed out (\(error.localizedDescription)).")
            // Invalidate the cached analyzer so the next press rebuilds it from scratch
            // rather than reusing a possibly-wedged instance, then propagate: the caller
            // surfaces a clean error and returns to idle.
            self.transcriber = nil
            self.analyzer = nil
            throw error
        }
    }

    /// The wake phrase, always seeded into the ASR context so the recognizer is biased
    /// toward "Jarvis" at the source. Without this the native model mishears "Hey Jarvis"
    /// as unrelated words ("Punjabi"), which then leaks into routing and learned memory.
    private static let wakeWords = ["Jarvis", "Hey Jarvis", "Sotto"]

    /// Custom vocabulary (Settings) + learned jargon, same sources `SottoIntelligence`
    /// injects into the polish prompt — fed here too so ASR gets them right at the source.
    /// The wake words are always included so summoning Jarvis transcribes reliably.
    private static func contextualVocabulary() -> [String] {
        let custom = SettingsController.customVocabulary
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let learned = UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? []
        // Wake words go first and are exempt from the cap — the 100-entry limit only trims
        // the (unbounded, ever-growing) learned/custom vocab, never the summon phrase.
        let extra = Set(custom + learned).subtracting(wakeWords)
        return wakeWords + Array(extra).prefix(max(0, 100 - wakeWords.count))
    }
}

// MARK: - Transcriber

/// Drives dictation through the native Apple `NativeDictationBackend` (SpeechAnalyzer).
/// A prepare/transcribe failure propagates to the caller rather than degrading to any
/// legacy engine.
actor Transcriber {
    enum TranscriberError: LocalizedError {
        case notReady
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Speech model is not loaded yet."
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
        // Self-heal after a memory-pressure unload() that landed between this press's
        // prewarm prepare() and its key-release — otherwise the press fails with notReady.
        if activeBackend == nil { try await prepare() }
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

    func unload() {
        // A live streaming pass owns transcriber.results and the analyzer; dropping the
        // backend mid-dictation would orphan the session and fail the in-flight press.
        // Eviction is opportunistic — skip and let a later pressure event reclaim it.
        if nativeDictationBackend?.isStreaming == true {
            print("[TRANSCRIBER] Skipping unload — streaming dictation in progress.")
            return
        }
        activeBackend = nil
        nativeDictationBackend = nil
        print("[TRANSCRIBER] Unloaded native dictation backend.")
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
