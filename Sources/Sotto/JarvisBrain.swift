import Foundation
import NaturalLanguage
import SottoCore

/// The associative command memory — the "hippocampus" between the Kernel's literal
/// reflexes and the Foundation Models LLM. It embeds remembered command phrases with
/// Apple's built-in `NLEmbedding` sentence model and matches new utterances by MEANING,
/// so "put the music on pause" fires the same action as a learned "pause spotify"
/// without waking the model.
///
/// Entries come from two sources:
/// - a versioned seed pack of paraphrases mapped to Kernel reflex capabilities (these
///   re-parse the raw utterance, so they carry no stored arguments), and
/// - CommandLearner promotions: phrases used ≥3 times with identical tool arguments
///   (`recordToolCall` argument-stability path) are replayed via
///   `JarvisToolbox.callToolNatively` with the captured args JSON.
actor JarvisBrain {
    static let shared = JarvisBrain()

    /// Tools safe to fire directly from memory: repeatable and non-destructive, with
    /// arguments that make sense to replay verbatim. Everything else stays behind the
    /// LLM even when learned (checked again at execution time, not just at remember).
    static let directExecutionAllowlist: Set<String> = [
        "control_spotify", "set_volume", "adjust_brightness",
        "open_website", "open_app", "web_search", "read_screen",
        "system_power_state", "recall_history",
        "morning_brief", "start_focus_session", "switch_workspace",
    ]

    private let maxEntries = 500
    private static let seedVersion = 1

    private struct BrainFile: Codable {
        var seedVersion: Int
        var entries: [BrainEntry]
    }

    private var entries: [BrainEntry] = []
    private var appliedSeedVersion = 0
    private var bootstrapped = false

    // Lazily loaded so the OS embedding asset costs nothing until the first recall,
    // and droppable under memory pressure (rebuilt on the next recall).
    private var embedder: NLEmbedding?
    private var triedLoadingEmbedder = false

    private var fileURL: URL {
        SettingsController.sottoDataURL.appendingPathComponent("jarvis_brain.json")
    }

    private init() {}

    // MARK: - Public API

    /// Best remembered action for the utterance, or nil (miss, below threshold,
    /// polarity conflict, or embedding asset unavailable) — nil always means
    /// "fall through to the LLM".
    func recall(utterance: String) -> (phrase: String, action: BrainAction)? {
        bootstrapIfNeeded()
        let clean = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 2, !entries.isEmpty, let qv = embed(clean) else { return nil }
        // Thresholds are calibrated to NLEmbedding's low-scoring scale and the guards
        // in CommandRecall.match (polarity + slot consistency) — see its doc comment.
        guard let hit = CommandRecall.match(
            queryVector: qv, queryPhrase: clean, entries: entries
        ) else { return nil }
        if case .tool(let name, _) = hit.entry.action,
           !Self.directExecutionAllowlist.contains(name) {
            return nil
        }
        print("[BRAIN] '\(clean.prefix(40))' ≈ '\(hit.entry.phrase)' (\(String(format: "%.2f", hit.similarity)))")
        return (hit.entry.phrase, hit.entry.action)
    }

    /// Remember a command (upserts by normalized phrase). Tool actions outside the
    /// direct-execution allowlist are refused — they must keep going through the LLM.
    func rememberCommand(phrase: String, action: BrainAction) {
        bootstrapIfNeeded()
        let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count > 2 else { return }
        if case .tool(let name, _) = action, !Self.directExecutionAllowlist.contains(name) { return }
        guard let vec = embed(clean) else { return }
        entries.removeAll { $0.phrase == clean }
        entries.append(BrainEntry(phrase: clean, vector: vec, action: action))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        save()
        print("[BRAIN] remembered '\(clean.prefix(50))' → \(action)")
    }

    /// Drop the resident embedding model under memory pressure. The entry vectors stay
    /// (a few hundred small arrays); the model reloads lazily on the next recall.
    func unload() {
        guard embedder != nil else { return }
        embedder = nil
        triedLoadingEmbedder = false
        Task { @MainActor in MemoryLedger.shared.recordEviction() }
        print("[BRAIN] Unloaded sentence embedding model (memory pressure).")
    }

    // MARK: - Internals

    private func bootstrapIfNeeded() {
        guard !bootstrapped else { return }
        bootstrapped = true
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(BrainFile.self, from: data) {
            entries = file.entries
            appliedSeedVersion = file.seedVersion
        }
        if appliedSeedVersion < Self.seedVersion {
            seed()
            appliedSeedVersion = Self.seedVersion
            save()
        }
        print("[BRAIN] Ready: \(entries.count) remembered command(s).")
    }

    /// Born-knowing basics: common paraphrases mapped to Kernel reflex capabilities
    /// (seeded in `Kernel.seedReflexes`). Kernel reflexes re-parse the raw utterance,
    /// so these carry no arguments and can never replay stale state. Phrases the
    /// literal keyword routers already catch don't need to be here — this net exists
    /// for wordings the registries miss.
    private func seed() {
        let seeds: [(String, BrainAction)] = [
            ("put on some music", .kernel(capability: "media_play")),
            ("start playing music", .kernel(capability: "media_play")),
            ("resume the music", .kernel(capability: "media_play")),
            ("play something for me", .kernel(capability: "media_play")),
            ("skip this song", .kernel(capability: "media_next")),
            ("play the next track", .kernel(capability: "media_next")),
            ("i don't like this song", .kernel(capability: "media_next")),
            ("go back a song", .kernel(capability: "media_prev")),
            ("play the previous track", .kernel(capability: "media_prev")),
        ]
        for (phrase, action) in seeds {
            rememberCommand(phrase: phrase, action: action)
        }
    }

    private func embed(_ text: String) -> [Double]? {
        if embedder == nil && !triedLoadingEmbedder {
            triedLoadingEmbedder = true
            embedder = NLEmbedding.sentenceEmbedding(for: .english)
            if embedder == nil { print("[BRAIN] Sentence embedding asset unavailable — brain recall disabled.") }
        }
        return embedder?.vector(for: text)
    }

    private func save() {
        let file = BrainFile(seedVersion: appliedSeedVersion, entries: entries)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
