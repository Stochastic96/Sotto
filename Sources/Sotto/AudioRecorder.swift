import AVFoundation
import CoreAudio
import AudioToolbox
import os

// MARK: - AudioCapturing Protocol

/// Abstracts microphone capture for the dictation pipeline.
/// Conform to swap in a test double that returns pre-recorded samples
/// without requiring microphone hardware or permission prompts in tests.
protocol AudioCapturing: AnyObject {
    var currentRMS: Float { get }
    func prewarm()
    func onSilenceDetected(_ handler: @escaping () -> Void)
    func start() throws
    func stop() -> [Float]
}

// MARK: - AudioRecorder

/// Captures microphone audio while the hotkey is held and converts it to
/// 16 kHz mono Float32 — the format FluidAudio/Parakeet expects.
final class AudioRecorder: @unchecked Sendable, AudioCapturing {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = OSAllocatedUnfairLock<Void>()

    // Cached hardware config — avoids re-enumerating all CoreAudio devices on every press.
    private var cachedBuiltInMicID: AudioDeviceID?
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

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func onSilenceDetected(_ handler: @escaping () -> Void) {
        self.silenceDetectedHandler = handler
    }

    /// Warms the CoreAudio device cache at launch so the first recording press doesn't
    /// pay the device-enumeration cost. Safe to call on any thread.
    func prewarm() {
        if cachedBuiltInMicID == nil {
            cachedBuiltInMicID = findBuiltInMicrophoneDeviceID()
            print("[AUDIO] Prewarmed mic ID: \(cachedBuiltInMicID.map { "\($0)" } ?? "not found")")
        }
    }

    func start() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            _currentRMS = 0.0
            silenceAccumulator = 0.0
        }

        let input = engine.inputNode

        // Always use the physical built-in mic, regardless of Bluetooth/external speaker state.
        // Use the cached device ID when available to avoid re-enumerating all CoreAudio devices.
        let builtInMicID = cachedBuiltInMicID ?? findBuiltInMicrophoneDeviceID()
        if cachedBuiltInMicID == nil { cachedBuiltInMicID = builtInMicID }
        if let builtInMicID {
            print("[AUDIO] Forcing built-in microphone input device ID: \(builtInMicID)")
            do {
                try setInputDevice(engine: engine, deviceID: builtInMicID)
            } catch {
                print("[AUDIO] Failed to set input device to built-in microphone: \(error.localizedDescription). Using default input.")
            }
        } else {
            print("[AUDIO] Built-in microphone not found. Using default input.")
        }

        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid hardware sample rate (0)"])
        }

        // Reuse the cached converter when the hardware format matches — AVAudioConverter
        // creation is non-trivial and the format is stable within a session.
        let converter: AVAudioConverter
        if let cached = cachedConverter, let fmt = cachedHwFormat,
           fmt.sampleRate == hwFormat.sampleRate && fmt.channelCount == hwFormat.channelCount {
            converter = cached
        } else {
            guard let fresh = AVAudioConverter(from: hwFormat, to: targetFormat) else {
                throw NSError(domain: "AudioRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter from \(hwFormat.sampleRate)Hz to 16000Hz"])
            }
            converter = fresh
            cachedConverter = fresh
            cachedHwFormat = hwFormat
        }

        // Strong capture: the tap is always removed in stop() before AudioRecorder can
        // deinit, so there is no retain cycle. A [weak self] capture here produces a
        // Sendable warning in Swift 6 because Optional<AudioRecorder> isn't Sendable.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [self] buffer, _ in
            append(buffer, using: converter)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            _currentRMS = 0.0
            return samples
        }
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
            lock.withLock { self._currentRMS = rms }

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

        // Convert to [Float] (Sendable) BEFORE entering the lock — crossing the lock
        // boundary with UnsafePointer<UnsafeMutablePointer<Float>?> triggers a Swift 6
        // Sendable diagnostic because UnsafePointer is not Sendable.
        let newSamples = [Float](UnsafeBufferPointer(start: channel[0], count: count))
        lock.withLock { samples.append(contentsOf: newSamples) }
    }

    // MARK: - Device discovery

    /// Finds the physical built-in microphone by CoreAudio transport type.
    /// This is reliable even when Bluetooth speakers/headsets are connected and
    /// macOS has switched the system default input away from the built-in mic.
    private func findBuiltInMicrophoneDeviceID() -> AudioDeviceID? {
        for deviceID in getAllDevices() {
            guard getTransportType(deviceID: deviceID) == kAudioDeviceTransportTypeBuiltIn,
                  hasInputChannels(deviceID: deviceID) else { continue }
            return deviceID
        }
        return nil
    }

    private func getTransportType(deviceID: AudioDeviceID) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &transportType)
        return transportType
    }

    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, buffer) == noErr else { return false }
        return buffer.load(as: AudioBufferList.self).mNumberBuffers > 0
    }

    private func getAllDevices() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        let retrieveStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        return retrieveStatus == noErr ? deviceIDs : []
    }

    private func setInputDevice(engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            throw NSError(domain: "AudioRecorder", code: -3, userInfo: [NSLocalizedDescriptionKey: "Input node audio unit is nil"])
        }

        var mDeviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mDeviceID,
            size
        )

        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AudioUnitSetProperty CurrentDevice failed with status \(status)"])
        }
    }
}
