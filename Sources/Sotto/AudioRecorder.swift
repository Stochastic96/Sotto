import AVFoundation

/// Captures microphone audio while the hotkey is held and converts it to
/// 16 kHz mono Float32 — the format FluidAudio/Parakeet expects.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()

    private var silenceDetectedHandler: (() -> Void)?
    private var silenceAccumulator: Double = 0.0
    private let silenceThreshold: Float = 0.015 // RMS threshold for silence (~ -36 dB)
    private let maxSilenceDuration: Double = 3.5 // 3.5 seconds of silence to trigger auto-stop
    private var _currentRMS: Float = 0.0
    var currentRMS: Float {
        lock.lock()
        defer { lock.unlock() }
        return _currentRMS
    }

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func onSilenceDetected(_ handler: @escaping () -> Void) {
        self.silenceDetectedHandler = handler
    }

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        _currentRMS = 0.0
        silenceAccumulator = 0.0
        lock.unlock()

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid hardware sample rate (0)"])
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter from \(hwFormat.sampleRate)Hz to 16000Hz"])
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        _currentRMS = 0.0
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        guard buffer.format.sampleRate > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData else { return }

        let count = Int(out.frameLength)
        
        // VAD / Silence detection logic
        if count > 0 {
            var sum: Float = 0.0
            for i in 0..<count {
                let sample = channel[0][i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(count))
            lock.lock()
            self._currentRMS = rms
            lock.unlock()
            
            if !SettingsController.isPushToTalk {
                if rms < silenceThreshold {
                    let duration = Double(count) / targetFormat.sampleRate
                    silenceAccumulator += duration
                    if silenceAccumulator >= maxSilenceDuration {
                        silenceAccumulator = 0.0
                        silenceDetectedHandler?()
                    }
                } else {
                    silenceAccumulator = 0.0
                }
            }
        }

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
        lock.unlock()
    }
}
