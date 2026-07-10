import Foundation

/// Append-only audit trail for the dictation → Jarvis bridge, written to
/// `sotto-data/bridge_audit.jsonl`. One record per bridge-relevant dictation utterance, so the
/// wake-word recognition rate, delegation rate, executions, and mishears can be audited offline.
///
/// Deliberately separate from `TaskJournal` (Jarvis's own activity log) and `DatasetLogger`
/// (audio + training pairs): this is a focused, text-only stream for measuring how well the
/// bridge hears "Jarvis" and whether it acted.
///
/// Fire-and-forget and self-synchronizing — every write does its own file I/O on a detached
/// task with no shared mutable state, so it is safe to call from any actor or thread. Auditing
/// must never break dictation, so nothing here throws.
enum BridgeAudit {
    /// The classification outcome, mirrored to a stable on-disk string. `.none` (plain
    /// dictation) is intentionally NOT logged — only bridge-relevant events land here.
    enum Outcome: String, Sendable {
        case delegated   // heard wake + task → routed to Jarvis and executed
        case noTask      // heard wake alone → nothing executed
        case nearMiss    // wake token mid-utterance → likely missed delegation (pasted as dictation)
    }

    /// Hard caps so a runaway transcript/reply can never bloat the audit file.
    private static let maxTranscript = 400
    private static let maxReply = 400

    private static var fileURL: URL {
        SettingsController.sottoDataURL.appendingPathComponent("bridge_audit.jsonl")
    }

    /// Record one bridge event. `reply`, `latencyMs`, and `error` are only meaningful for
    /// `.delegated` and may be omitted otherwise. Fire-and-forget; never throws.
    static func record(
        outcome: Outcome,
        transcript: String,
        command: String,
        app: String?,
        reply: String? = nil,
        latencyMs: Double? = nil,
        error: String? = nil
    ) {
        // Build the record on the calling thread (cheap, no shared state) so the detached
        // task only performs I/O with already-sanitized values.
        var record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "outcome": outcome.rawValue,
            "delegated": outcome == .delegated,
            "transcript": cap(transcript, maxTranscript),
            "command": cap(command, maxTranscript),
            "app": app ?? "",
        ]
        if let reply { record["reply"] = cap(reply, maxReply) }
        if let latencyMs { record["latency_ms"] = Int(latencyMs.rounded()) }
        if let error { record["error"] = cap(error, maxReply) }

        Task.detached {
            guard let data = try? JSONSerialization.data(withJSONObject: record),
                  let line = String(data: data, encoding: .utf8) else { return }
            append(line + "\n")
        }
    }

    /// The most recent `limit` events as readable one-liners, newest last. For quick auditing.
    static func recent(limit: Int = 20) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "No bridge events recorded yet."
        }
        let lines = text.split(separator: "\n").suffix(limit)
        var out: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ts = (obj["ts"] as? String)?.prefix(16) ?? ""
            let outcome = obj["outcome"] as? String ?? "?"
            let cmd = obj["command"] as? String ?? ""
            let reply = obj["reply"] as? String ?? ""
            let tail = reply.isEmpty ? "" : " → \(reply)"
            out.append("[\(ts)] \(outcome) \"\(cmd)\"\(tail)")
        }
        return out.isEmpty ? "No bridge events recorded yet." : out.joined(separator: "\n")
    }

    /// Aggregate counts across the whole log — the headline audit numbers.
    static func summary() -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "No bridge events recorded yet."
        }
        var counts: [String: Int] = [:]
        var total = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outcome = obj["outcome"] as? String else { continue }
            counts[outcome, default: 0] += 1
            total += 1
        }
        guard total > 0 else { return "No bridge events recorded yet." }
        let delegated = counts[Outcome.delegated.rawValue] ?? 0
        let noTask = counts[Outcome.noTask.rawValue] ?? 0
        let nearMiss = counts[Outcome.nearMiss.rawValue] ?? 0
        return """
        Bridge audit: \(total) events — \(delegated) delegated, \(noTask) no-task, \(nearMiss) near-miss.
        """
    }

    // MARK: - Private

    /// Truncate free text with an ellipsis so the log stays bounded.
    private static func cap(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    /// Append one line, creating the file on first write. Mirrors `TaskJournal`.
    private static func append(_ line: String) {
        guard let payload = line.data(using: .utf8) else { return }
        let url = fileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? payload.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(payload)
    }
}
