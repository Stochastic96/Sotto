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

// MARK: - Apple Speech (SFSpeechRecognizer)

private struct AppleSpeechBackend: TranscriptionBackend {
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
                try? await Task.sleep(for: .seconds(8))
                let resumeText: String? = state.withLock { s in
                    guard !s.finished else { return nil }
                    s.finished = true
                    return s.partial
                }
                if let text = resumeText {
                    box.task?.cancel()
                    print("[TRANSCRIBER] Apple Speech timed out after 8s; returning best partial (\(text.count) chars).")
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
            return backend
        case .appleSpeech:
            parakeetBackend = nil  // release model weights when switching away
            return AppleSpeechBackend()
        }
    }
}
