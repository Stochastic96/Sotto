import Foundation

/// Append-only journal of what Jarvis actually did, so it can summarize on request
/// ("what did you do today?"). Separate from DatasetLogger (which captures audio +
/// full training pairs) — this is a small, fast, text-only log for recall.
enum TaskJournal {
    private static let io = DispatchQueue(label: "sotto.task.journal")

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Sotto/sotto-data/journal.jsonl")
    }

    /// Record one completed action. Fire-and-forget.
    static func record(command: String, reply: String) {
        io.async {
            let record: [String: Any] = [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "command": command,
                "reply": reply
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: record),
                  let line = String(data: data, encoding: .utf8) else { return }
            let url = fileURL
            let fm = FileManager.default
            let payload = (line + "\n").data(using: .utf8)!
            if !fm.fileExists(atPath: url.path) {
                try? payload.write(to: url)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(payload)
            }
        }
    }

    /// The most recent `limit` entries as readable "command → reply" lines.
    static func recent(limit: Int = 20) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "No activity recorded yet."
        }
        let lines = text.split(separator: "\n").suffix(limit)
        var out: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ts = (obj["ts"] as? String)?.prefix(16) ?? ""
            let cmd = obj["command"] as? String ?? ""
            let reply = obj["reply"] as? String ?? ""
            out.append("[\(ts)] \"\(cmd)\" → \(reply)")
        }
        return out.isEmpty ? "No activity recorded yet." : out.joined(separator: "\n")
    }
}
