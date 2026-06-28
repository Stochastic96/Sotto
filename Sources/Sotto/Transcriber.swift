import Foundation
import FluidAudio
import os
@preconcurrency import Speech
import AVFoundation

/// Wraps speech recognition engines. Supports both:
/// 1. FluidAudio's Parakeet TDT v3 offline AI model on Apple Neural Engine (ANE).
/// 2. Apple's Speech Recognition framework (Siri engine) which starts instantly,
///    runs offline or online depending on locale/system settings, and supports all macOS languages.
final class Transcriber {
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

    private var manager: AsrManager?

    func prepare() async throws {
        let engine = SettingsController.transcriptionEngine
        print("[TRANSCRIBER] Preparing engine: \(engine.rawValue)")
        
        switch engine {
        case .offlineAI:
            if manager == nil {
                let models = try await AsrModels.downloadAndLoad()
                manager = AsrManager(config: .default, models: models)
            }
        case .appleSpeech:
            self.manager = nil
            let status = SFSpeechRecognizer.authorizationStatus()
            if status == .notDetermined {
                let authorized = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status == .authorized)
                    }
                }
                if !authorized {
                    throw TranscriberError.permissionDenied
                }
            } else if status != .authorized {
                throw TranscriberError.permissionDenied
            }
        }
    }

    /// `samples` must be 16 kHz mono Float32.
    func transcribe(_ samples: [Float]) async throws -> String {
        let engine = SettingsController.transcriptionEngine
        print("[TRANSCRIBER] Transcribing with engine: \(engine.rawValue)")
        
        switch engine {
        case .offlineAI:
            guard let manager else { throw TranscriberError.notReady }
            // Fresh decoder state per utterance — dictation bursts are independent.
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            return result.text
            
        case .appleSpeech:
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                throw TranscriberError.speechRecognizerNotAvailable
            }
            
            // Create target format (16kHz PCM Float32 mono) matching recorder output
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )!
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw NSError(domain: "Transcriber", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM buffer for Speech Recognition"])
            }
            
            buffer.frameLength = buffer.frameCapacity
            if let channelData = buffer.floatChannelData {
                samples.withUnsafeBufferPointer { ptr in
                    channelData[0].initialize(from: ptr.baseAddress!, count: samples.count)
                }
            }
            
            let request = SFSpeechAudioBufferRecognitionRequest()
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            
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
            let box = TaskBox()
            struct SpeechState { var finished = false; var partial = "" }
            let state = OSAllocatedUnfairLock(initialState: SpeechState())
            return try await withCheckedThrowingContinuation { continuation in
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    // withLock owns both fields; returning String? avoids capturing a var.
                    let resumeText: String? = state.withLock { s in
                        guard !s.finished else { return nil }
                        if let result {
                            s.partial = result.bestTranscription.formattedString
                            if result.isFinal {
                                s.finished = true
                                return s.partial
                            }
                        }
                        if error != nil {
                            s.finished = true
                            // Prefer any partial we captured; treat "no speech
                            // detected" as an empty (silent) result, not a hard failure.
                            return s.partial
                        }
                        return nil
                    }
                    if let text = resumeText {
                        continuation.resume(returning: text)
                    }
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
}
