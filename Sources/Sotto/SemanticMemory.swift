import Foundation
import NaturalLanguage
import CoreSpotlight

/// One remembered snippet plus its embedding vector.
struct MemoryEntry: Codable {
    let id: String
    let text: String
    let kind: String        // "profile" | "journal" | "note"
    let vector: [Double]
    let createdAt: Date
}

/// On-device semantic memory. Uses Apple's built-in `NLEmbedding` sentence model (no model
/// download, fits the 8 GB budget) to embed what Jarvis learns about the user and what it has
/// done, then recalls the most relevant snippets for the current utterance so the assistant
/// "remembers you" instead of starting cold every turn. Stored as JSON in `sotto-data/`.
enum SemanticMemory {
    private static let io = DispatchQueue(label: "sotto.semantic.memory")
    private static let maxEntries = 400

    private static var fileURL: URL {
        SettingsController.sottoDataURL.appendingPathComponent("semantic_memory.json")
    }

    // Built-in sentence embedding; nil if the OS asset isn't available (recall then no-ops).
    private static let embedder: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    // MARK: - Embedding

    /// Embed text into a vector. Must be called on `io` so the shared model is touched from a
    /// single queue.
    private static func embed(_ text: String) -> [Double]? {
        guard let embedder else { return nil }
        return embedder.vector(for: text)
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    // MARK: - Persistence

    private static func loadAll() -> [MemoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MemoryEntry].self, from: data)) ?? []
    }

    private static func saveAll(_ entries: [MemoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Public API

    /// Remember a snippet. De-dupes identical text and keeps the store bounded (drops oldest).
    /// Fire-and-forget; safe to call from any thread.
    static func remember(_ text: String, kind: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 3 else { return }
        io.async {
            guard let vec = embed(clean) else { return }   // no embedding asset → skip
            var all = loadAll()
            if all.contains(where: { $0.text == clean && $0.kind == kind }) { return }
            let entry = MemoryEntry(id: UUID().uuidString, text: clean, kind: kind, vector: vec, createdAt: Date())
            all.append(entry)
            if all.count > maxEntries {
                let removed = all.removeFirst()
                deleteFromSpotlight(id: removed.id)
            }
            saveAll(all)
            print("[MEMORY] +\(kind) (\(all.count) total): \(clean.prefix(70))")
            indexInSpotlight(entry: entry)
        }
    }

    private static func indexInSpotlight(entry: MemoryEntry) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = "Jarvis Memory (\(entry.kind))"
        attributeSet.contentDescription = entry.text
        
        let item = CSSearchableItem(
            uniqueIdentifier: "sotto:memory:\(entry.id)",
            domainIdentifier: "sotto.memory",
            attributeSet: attributeSet
        )
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error = error {
                print("[MEMORY] CoreSpotlight index error: \(error.localizedDescription)")
            }
        }
    }

    private static func deleteFromSpotlight(id: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ["sotto:memory:\(id)"]) { error in
            if let error = error {
                print("[MEMORY] CoreSpotlight delete error: \(error.localizedDescription)")
            }
        }
    }

    /// The `limit` stored snippets most semantically similar to `query` (above a minimum
    /// similarity so unrelated memories aren't dredged up). Fast for a few hundred entries.
    static func recall(for query: String, limit: Int = 3, minSimilarity: Double = 0.40) -> [String] {
        io.sync {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count > 2, let qv = embed(q) else { return [] }
            let scored: [(Double, String)] = loadAll().compactMap { entry in
                let s = cosine(qv, entry.vector)
                return s >= minSimilarity ? (s, entry.text) : nil
            }
            let hits = scored.sorted { $0.0 > $1.0 }.prefix(limit).map { $0.1 }
            print("[MEMORY] recall '\(q.prefix(40))' → \(hits.count) hit(s)")
            return hits
        }
    }
}
