import Foundation

/// Small append-only diagnostic log for the hotkey → recording state machine.
/// Sotto prints these events with `print()`, which only reaches stdout — invisible
/// once the app runs as a bundle. This mirrors the important lifecycle events to
/// `sotto-data/hotkey.log` so intermittent "the hotkey did nothing" reports are
/// actually debuggable after the fact. Fire-and-forget; never throws to callers.
enum SottoLog {
    private static var fileURL: URL {
        SettingsController.sottoDataURL.appendingPathComponent("hotkey.log")
    }

    /// Trim the log to its last half once it grows past this, so it can't grow
    /// unbounded on the 8 GB target.
    private static let maxBytes = 512 * 1024

    /// Record one event. Also echoes to stdout so terminal runs keep the old behavior.
    static func event(_ message: String) {
        print("[APP] \(message)")
        let stamp = Date().ISO8601Format()
        Task.detached {
            let line = "[\(stamp)] \(message)\n"
            guard let payload = line.data(using: .utf8) else { return }
            let url = fileURL
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? payload.write(to: url)
                return
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(payload)
            }
            rotateIfNeeded(url)
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Keep the most recent half of the lines.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}
