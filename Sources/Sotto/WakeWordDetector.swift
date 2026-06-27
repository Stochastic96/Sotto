import Foundation
import Speech
import AVFoundation

/// Background listener that leverages macOS's native on-device Speech Recognizer
/// to continuously listen for "Hey Jarvis", "Jarvis", or "Sotto" wake words.
/// Runs completely offline on the Apple Neural Engine with close-to-zero CPU.
@available(macOS 10.15, *)
final class WakeWordDetector {
    private let speechRecognizer: SFSpeechRecognizer
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let queue = DispatchQueue(label: "local.sotto.wakeword")
    private var isRunning = false
    
    var onWakeWordDetected: (() -> Void)?

    init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()!
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true
            self.setupAndStart()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.isRunning = false
            self.teardown()
        }
    }

    private func setupAndStart() {
        // Check permissions and request authorization
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
        guard authStatus == .authorized else {
            print("[WAKE] Speech recognition authorization not granted.")
            return
        }

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true // Enforce local model execution on Neural Engine
        self.recognitionRequest = request

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install audio tap to process microphone input
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[WAKE] Failed to start AVAudioEngine: \(error.localizedDescription)")
            teardown()
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let transcription = result.bestTranscription.formattedString.lowercased()
                
                // Wake word matches
                if transcription.contains("hey jarvis") || transcription.contains("jarvis") || transcription.contains("sotto") {
                    print("[WAKE] Spoken wake word detected! Transcript: '\(transcription)'")
                    
                    // Stop to release audio input for primary dictation recording
                    self.stop()
                    
                    Task { @MainActor [self] in
                        self.onWakeWordDetected?()
                    }
                }
            }
            if let error = error {
                let nsError = error as NSError
                // SFSpeechRecognizer occasionally times out or restarts task, this is expected behavior.
                // We restart if we are still active.
                if self.isRunning && nsError.code != 301 && nsError.domain != "kAFAssistantErrorDomain" {
                    print("[WAKE] Task encountered error, restarting: \(error.localizedDescription)")
                    self.restart()
                }
            }
        }
        print("[WAKE] Spoken wake word detector running offline.")
    }

    private func restart() {
        teardown()
        if isRunning {
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.setupAndStart()
            }
        }
    }

    private func teardown() {
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        audioEngine = nil
        print("[WAKE] Spoken wake word detector stopped.")
    }
}
