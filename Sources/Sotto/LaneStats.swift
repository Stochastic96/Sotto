import Foundation

// MARK: - LaneStats
//
// Measures the three-lane distribution the architecture is built around: what
// fraction of Jarvis commands are handled by a 0-token reflex vs. the on-device
// Apple Intelligence agent vs. the heavier MLX/cloud paths, and how long each took.
//
// The goal (per the design): ~80–90% reflex, ~8–15% apple, ~1–5% mlx/cloud. Without
// numbers that target is a guess — this turns it into a measurement. Counts persist
// across launches so the distribution reflects real usage, not one session.

enum Lane: String, Sendable, CaseIterable {
    case reflex   // pure Swift, 0 tokens (zero-latency shortcut, kernel reflex, weather, Siri)
    case apple    // Apple Intelligence Foundation Models agent
    case mlx      // on-device Qwen sub-agent
    case cloud    // Claude CLI / external
    case failed   // nothing handled it
}

actor LaneStats {
    static let shared = LaneStats()

    struct Bucket: Codable, Sendable {
        var count = 0
        var totalMs = 0.0
        var maxMs = 0.0
    }

    private var buckets: [String: Bucket]
    private static let defaultsKey = "sotto_lane_stats"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Bucket].self, from: data) {
            buckets = decoded
        } else {
            buckets = [:]
        }
    }

    func record(lane: Lane, ms: Double) {
        var b = buckets[lane.rawValue] ?? Bucket()
        b.count += 1
        b.totalMs += ms
        b.maxMs = max(b.maxMs, ms)
        buckets[lane.rawValue] = b
        if let data = try? JSONEncoder().encode(buckets) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func reset() {
        buckets.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    /// Human-readable distribution table for the log/explanation window.
    func summary() -> String {
        let total = buckets.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return "No Jarvis commands recorded yet." }

        var lines = ["# Jarvis Lane Distribution", "", "\(total) commands recorded.", ""]
        lines.append("| Lane | Count | Share | Avg | Max |")
        lines.append("| :--- | ---: | ---: | ---: | ---: |")
        for lane in Lane.allCases {
            guard let b = buckets[lane.rawValue], b.count > 0 else { continue }
            let share = Double(b.count) / Double(total) * 100
            let avg = b.totalMs / Double(b.count)
            lines.append(String(format: "| %@ | %d | %.0f%% | %.0f ms | %.0f ms |",
                                lane.rawValue, b.count, share, avg, b.maxMs))
        }
        return lines.joined(separator: "\n")
    }
}
