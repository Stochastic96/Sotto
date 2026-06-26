import Foundation
import FluidAudio
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
            let lock = NSLock()
            var finished = false
            var latestPartial = ""
            return try await withCheckedThrowingContinuation { continuation in
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    lock.lock()
                    if finished { lock.unlock(); return }
                    if let result = result {
                        latestPartial = result.bestTranscription.formattedString
                        if result.isFinal {
                            finished = true
                            lock.unlock()
                            continuation.resume(returning: result.bestTranscription.formattedString)
                            return
                        }
                    }
                    if let error = error {
                        finished = true
                        let partial = latestPartial
                        lock.unlock()
                        // Prefer any partial we captured; otherwise treat "no speech
                        // detected" as an empty (silent) result, not a hard failure.
                        continuation.resume(returning: partial)
                        _ = error
                        return
                    }
                    lock.unlock()
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + 8.0) {
                    lock.lock()
                    if finished { lock.unlock(); return }
                    finished = true
                    let partial = latestPartial
                    lock.unlock()
                    box.task?.cancel()
                    print("[TRANSCRIBER] Apple Speech timed out after 8s; returning best partial (\(partial.count) chars).")
                    continuation.resume(returning: partial)
                }
            }
        }
    }
}
