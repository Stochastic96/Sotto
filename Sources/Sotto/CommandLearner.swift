import Foundation
import os

/// Learns which Jarvis phrases you use repeatedly and promotes them so
/// JarvisToolbox.routed(for:) pre-selects the right tool immediately —
/// no more keyword scoring for commands you already use every day.
///
/// Flow:
///   CoordinatorAgent records (phrase, toolName) after each successful turn.
///   After `promotionThreshold` uses, the phrase is "promoted".
///   JarvisToolbox.routed(for:) calls CommandLearner.hint(for:) and puts
///   the learned tool first, so the on-device model sees the correct tool as
///   option #1 instead of picking from a scored keyword list.
actor CommandLearner {
    static let shared = CommandLearner()

    struct Entry: Codable {
        var phrase: String
        var toolName: String?
        var count: Int
        var promoted: Bool
    }

    // OSAllocatedUnfairLock for synchronous reads from JarvisToolbox.routed
    // (no actor hop needed — routed is called on the model inference path).
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private var entries: [String: Entry] = [:]
    private let threshold = 3

    private lazy var fileURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Projects/Sotto/sotto-data/learned_shortcuts.json")
    }()

    private init() {}

    // MARK: - Startup

    /// Load persisted entries and warm the hint cache. Call once at launch.
    func bootstrap() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: decoded.map { (Self.normalize($0.phrase), $0) })
        refreshCache()
        let promoted = Self.cache.withLock { $0.count }
        print("[LEARNER] Loaded \(entries.count) entries, \(promoted) promoted.")
    }

    // MARK: - Recording

    /// Record a completed Jarvis turn. `toolName` is the tool the model used (optional).
    /// Call this after every successful CoordinatorAgent.handleTurn.
    func record(phrase: String, toolName: String? = nil) {
        let key = Self.normalize(phrase)
        guard key.count > 5 else { return }

        var e = entries[key] ?? Entry(phrase: key, toolName: nil, count: 0, promoted: false)
        e.count += 1
        if e.toolName == nil, let t = toolName { e.toolName = t }
        if !e.promoted && e.count >= threshold {
            e.promoted = true
            print("[LEARNER] Promoted '\(key)' -> \(e.toolName ?? "unknown tool")")
        }
        entries[key] = e
        refreshCache()
        save()
    }

    // MARK: - Synchronous hint query (no await — called from JarvisToolbox.routed)

    /// Returns the learned tool name for a promoted phrase, or nil.
    nonisolated static func hint(for phrase: String) -> String? {
        let key = normalize(phrase)
        return cache.withLock { $0[key] }
    }

    // MARK: - Inspection

    func allPromoted() -> [Entry] {
        entries.values.filter { $0.promoted }.sorted { $0.count > $1.count }
    }

    // MARK: - Internals

    private func refreshCache() {
        let pairs: [(String, String)] = entries.values.compactMap { e in
            guard e.promoted, let tool = e.toolName else { return nil }
            return (e.phrase, tool)
        }
        Self.cache.withLock { $0 = Dictionary(uniqueKeysWithValues: pairs) }
    }

    private func save() {
        let arr = Array(entries.values)
        guard let data = try? JSONEncoder().encode(arr) else { return }
        try? data.write(to: fileURL)
    }

    nonisolated static func normalize(_ phrase: String) -> String {
        var s = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") || s.hasSuffix(",") || s.hasSuffix("?") || s.hasSuffix("!") {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Reply-to-tool inference

extension CommandLearner {
    /// Infer which tool was used from the one-line reply Jarvis returns.
    /// Covers the most common tools without any instrumentation overhead.
    static func inferTool(from reply: String) -> String? {
        let r = reply.lowercased()
        if r.contains("spotify") || r.contains("playing.") || r.contains("paused.") ||
           r.contains("skipped") || r.contains("back to the previous") { return "control_spotify" }
        if r.contains("volume set") || r.contains("muted.") || r.contains("unmuted.") { return "set_volume" }
        if r.contains("brightness") { return "adjust_brightness" }
        if r.contains("searching the web") { return "web_search" }
        if r.contains("wikipedia") { return "wikipedia_lookup" }
        if r.contains("opened") && (r.contains("http") || r.contains("://")) { return "open_website" }
        if r.contains("opened") { return "open_app" }
        if r.contains("note saved") { return "create_note" }
        if r.contains("clipboard") { return "manage_clipboard" }
        if r.contains("clicked '") { return "click_element" }
        if r.contains("screen text") { return "read_screen" }
        if r.contains("battery") && r.contains("wi-fi") { return "get_system_status" }
        if r.contains("total ram") { return "get_ram_status" }
        if r.contains("gpu model") || r.contains("metal") { return "get_gpu_status" }
        if r.contains("internet reachable") { return "network_diagnostics" }
        if r.contains("coordinates:") { return "geocode_location" }
        if r.contains("handing query") || r.contains("delegating query") { return "ask_siri" }
        if r.contains("locking screen") || r.contains("emptying trash") { return "system_power_state" }
        if r.contains("claude response") { return "ask_claude" }
        if r.contains("queued '") || r.contains("task queue") { return "manage_tasks" }
        if r.contains("recent activity") { return "recall_history" }
        return nil
    }
}
