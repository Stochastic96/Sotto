import AVFoundation
import os

extension AVAudioNode {
    /// Bridge to the macOS 27 throwing replacement for the deprecated
    /// `installTap(onBus:bufferSize:format:block:)`. The new method is
    /// `NS_REFINED_FOR_SWIFT` but its Swift refinement is missing from the current
    /// Xcode 27 beta SDK, so it only surfaces under its raw imported name
    /// (`__installTap(...error:())`). When a later SDK ships the proper refinement,
    /// delete this shim and call `try installTap(...)` directly at the two call sites.
    func installTapCompat(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) throws {
        try __installTap(onBus: bus, bufferSize: bufferSize, format: format, error: (), block: block)
    }
}

final class SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Abstracts microphone capture for the dictation pipeline.
/// Conform to swap in a test double that returns pre-recorded samples
/// without requiring microphone hardware or permission prompts in tests.
protocol AudioCapturing: AnyObject {
    var currentRMS: Float { get }
    func onSilenceDetected(_ handler: @escaping () -> Void)
    func start(onBuffer: (@Sendable (SendableAudioBuffer) -> Void)?) throws
    func stop() -> [Float]
}

// MARK: - AudioRecorder

/// Captures microphone audio while the hotkey is held and converts it to
/// 16 kHz mono Float32 — the capture format the SpeechAnalyzer dictation path uses.
final class AudioRecorder: @unchecked Sendable, AudioCapturing {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = OSAllocatedUnfairLock<Void>()

    // Cached hardware→16 kHz converter, rebuilt only when the input format changes.
    private var cachedConverter: AVAudioConverter?
    private var cachedHwFormat: AVAudioFormat?

    private var silenceDetectedHandler: (() -> Void)?
    private var silenceAccumulator: Double = 0.0
    private let silenceThreshold: Float = 0.015 // RMS threshold for silence (~ -36 dB)
    private let maxSilenceDuration: Double = 3.5 // 3.5 seconds of silence to trigger auto-stop
    private var _currentRMS: Float = 0.0
    var currentRMS: Float {
        lock.withLock { _currentRMS }
    }
    private var configChangeObserver: NSObjectProtocol?
    private var onBufferCallback: (@Sendable (SendableAudioBuffer) -> Void)?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init() {
        observeAudioRouteChanges()
    }

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // When a speaker or headphone is connected/disconnected, AVAudioEngine's internal
    // hardware state becomes invalid. If we don't reset before the next start(), the
    // engine crashes. Observing AVAudioEngineConfigurationChange lets us tear down the
    // stale state safely between recordings.
    private func observeAudioRouteChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("[AUDIO] Hardware route changed — invalidating cached audio config.")
            if self.engine.isRunning {
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
            }
            // Discard the stale converter; it's rebuilt on the next append(). Guard with the
            // capture lock — append() reads/writes the same fields on the CoreAudio thread,
            // and an unsynchronized ARC store to the AVAudioConverter? reference can crash.
            self.lock.withLock {
                self.cachedConverter = nil
                self.cachedHwFormat = nil
            }
        }
    }

    func onSilenceDetected(_ handler: @escaping () -> Void) {
        self.silenceDetectedHandler = handler
    }

    func start(onBuffer: (@Sendable (SendableAudioBuffer) -> Void)? = nil) throws {
        // onBufferCallback is read on the CoreAudio thread in append() — guard it with
        // the same lock as the rest of the shared capture state.
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            _currentRMS = 0.0
            silenceAccumulator = 0.0
            onBufferCallback = onBuffer
        }

        let input = engine.inputNode

        // We deliberately do NOT force the input device via AudioUnitSetProperty here.
        // Switching kAudioOutputUnitProperty_CurrentDevice posts an
        // AVAudioEngineConfigurationChange DURING start(), which our own observer reacts to
        // by tearing down the tap and stopping the engine we're mid-way through starting —
        // and it also desyncs the node format (44100 graph vs 48000 hardware) → -10868, so
        // recording never begins. Use whatever macOS has selected as the current input
        // device; the converter below adapts any sample rate to 16 kHz.

        // The tap MUST use the input node's INPUT format (the real hardware rate, e.g.
        // 48000 Hz), NOT its output format. On an input node, outputFormat(forBus:) — and
        // therefore `format: nil` — returns a stale 44100 Hz default, which mismatches the
        // 48000 Hz hardware and fails graph init with -10868 ("formats don't match"), so no
        // audio is ever captured. inputFormat(forBus:) reflects the actual device.
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid hardware input sample rate (0)"])
        }
        print("[AUDIO] Installing tap at hardware input format: \(Int(hwFormat.sampleRate))Hz, \(hwFormat.channelCount)ch")

        // Strong capture: the tap is always removed in stop() before AudioRecorder can
        // deinit, so there is no retain cycle. A [weak self] capture here produces a
        // Sendable warning in Swift 6 because Optional<AudioRecorder> isn't Sendable.
        input.removeTap(onBus: 0)
        try input.installTapCompat(onBus: 0, bufferSize: 4096, format: hwFormat) { [self] buffer, _ in
            append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            _currentRMS = 0.0
            onBufferCallback = nil
            return samples
        }
    }

    /// Returns a cached converter from `format` → 16 kHz mono, rebuilding only when the
    /// incoming hardware format actually changes. Called on the CoreAudio capture thread;
    /// the config-change observer may clear the cache from the main thread, so all access to
    /// the cache fields is serialized by `lock`. Not called while `lock` is already held.
    private func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        lock.withLock {
            if let cached = cachedConverter, let fmt = cachedHwFormat,
               fmt.sampleRate == format.sampleRate && fmt.channelCount == format.channelCount {
                return cached
            }
            guard let fresh = AVAudioConverter(from: format, to: targetFormat) else { return nil }
            cachedConverter = fresh
            cachedHwFormat = format
            return fresh
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate > 0, let converter = converter(for: buffer.format) else { return }
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
        let triggerSilence: Bool

        if count > 0 {
            var sum: Float = 0.0
            for i in 0..<count {
                let sample = channel[0][i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(count))
            
            triggerSilence = lock.withLock {
                self._currentRMS = rms
                
                if !SettingsController.isPushToTalk {
                    if rms < silenceThreshold {
                        let duration = Double(count) / targetFormat.sampleRate
                        silenceAccumulator += duration
                        if silenceAccumulator >= maxSilenceDuration {
                            silenceAccumulator = 0.0
                            return true
                        }
                    } else {
                        silenceAccumulator = 0.0
                    }
                }
                return false
            }
        } else {
            triggerSilence = false
        }

        let newSamples = [Float](UnsafeBufferPointer(start: channel[0], count: count))
        // Snapshot the callback under the lock, invoke it OUTSIDE — same rule as the
        // silence handler: never call out to foreign code while holding the capture lock.
        let onBuffer = lock.withLock { () -> (@Sendable (SendableAudioBuffer) -> Void)? in
            samples.append(contentsOf: newSamples)
            return onBufferCallback
        }
        onBuffer?(SendableAudioBuffer(out))

        if triggerSilence {
            silenceDetectedHandler?()
        }
    }
}
