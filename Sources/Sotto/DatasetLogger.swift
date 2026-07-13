import Foundation

/// Captures every Jarvis/dictation interaction as a growing training dataset:
///   - your voice audio (16 kHz mono WAV) → for voice cloning + STT fine-tune later
///   - raw transcript → Jarvis response pairs → for LoRA fine-tune + prompting
/// Append-only JSONL so a crash never corrupts history. Lives in sotto-data/dataset/.
// All stored state is immutable (`let` URLs); every method does its own file I/O
// with no shared mutable state, so this is safe to share across threads.
final class DatasetLogger: @unchecked Sendable {
    static let shared = DatasetLogger()

    private let baseDir: URL
    private let audioDir: URL
    private let jsonlURL: URL

    private init() {
        baseDir = SettingsController.sottoDataURL.appendingPathComponent("dataset")
        audioDir = baseDir.appendingPathComponent("audio")
        jsonlURL = baseDir.appendingPathComponent("interactions.jsonl")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    }

    /// Log one interaction. `samples` = 16 kHz mono Float (your voice), optional.
    func log(mode: String,
             app: String?,
             rawTranscript: String,
             response: String,
             kind: String,
             samples: [Float]? = nil) {
        Task.detached { [self] in
            let id = UUID().uuidString
            var audioRel = ""
            if let samples, !samples.isEmpty,
               self.writeWav(samples, to: self.audioDir.appendingPathComponent("\(id).wav")) {
                audioRel = "audio/\(id).wav"
            }

            let record: [String: Any] = [
                "id": id,
                "ts": Date().ISO8601Format(),
                "mode": mode,
                "app": app ?? "",
                "raw_transcript": rawTranscript,
                "response": response,
                "kind": kind,
                "audio_file": audioRel
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: record),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.append(json + "\n")
            print("[DATASET] Logged \(kind) interaction \(id) (audio: \(audioRel.isEmpty ? "none" : audioRel))")
        }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: jsonlURL.path) {
            try? data.write(to: jsonlURL)
            return
        }
        if let handle = try? FileHandle(forWritingTo: jsonlURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    /// Minimal 16 kHz mono PCM16 WAV writer (no AVFoundation dependency).
    private func writeWav(_ samples: [Float], to url: URL, sampleRate: Int = 16000) -> Bool {
        let count = samples.count
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        let dataSize = count * 2
        var out = Data()
        func str(_ s: String) { out.append(Data(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 2)) }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(dataSize))
        pcm.withUnsafeBytes { out.append(contentsOf: $0) }
        do { try out.write(to: url); return true } catch {
            print("[DATASET] WAV write failed: \(error.localizedDescription)")
            return false
        }
    }
}
