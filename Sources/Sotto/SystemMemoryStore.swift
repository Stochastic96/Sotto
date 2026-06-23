import Foundation

struct MemoryItem: Codable {
    let key: String
    let value: String
    let category: String
    let updatedAt: Date
}

enum SystemMemoryStore {
    private static let dbURL: URL = {
        return SettingsController.sottoDataURL.appendingPathComponent("jarvis_memory.json")
    }()

    private static func loadAll() -> [String: MemoryItem] {
        guard let data = try? Data(contentsOf: dbURL),
              let list = try? JSONDecoder().decode([MemoryItem].self, from: data) else {
            return [:]
        }
        return list.reduce(into: [String: MemoryItem]()) { $0[$1.key] = $1 }
    }

    private static func save(_ items: [String: MemoryItem]) {
        let array = Array(items.values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(array) {
            // Ensure parent directory exists
            try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dbURL, options: .atomic)
        }
    }

    static func set(key: String, value: String, category: String = "general") {
        var items = loadAll()
        items[key] = MemoryItem(key: key, value: value, category: category, updatedAt: Date())
        save(items)
        print("[MEMORY-SWIFT] Set \(key) = \(value) (\(category))")
    }

    static func get(key: String) -> String? {
        let items = loadAll()
        return items[key]?.value
    }

    static func list(category: String) -> [String: String] {
        let items = loadAll()
        return items.filter { $0.value.category == category }
                    .reduce(into: [String: String]()) { $0[$1.key] = $1.value.value }
    }
}

/// A small, lightweight profile of the user (likes/dislikes/preferences) layered on top of
/// `SystemMemoryStore`'s "profile" category. Capped so it stays cheap to inject into the
/// agent's instructions, and only injected when non-empty — zero cost when the user hasn't
/// taught Jarvis anything yet.
enum UserProfile {
    private static let category = "profile"
    private static let maxFacts = 12

    /// Save (or overwrite) one durable fact. Keys are namespaced so they never collide with
    /// other memory categories.
    static func remember(key: String, fact: String) {
        // Trim the oldest facts if we're at the cap and this is a new key.
        let existing = SystemMemoryStore.list(category: category)
        let namespaced = "profile_\(key)"
        if existing[namespaced] == nil, existing.count >= maxFacts {
            // Best-effort: drop nothing fancy — just don't grow unboundedly. Overwrite the
            // first existing key so the profile stays bounded.
            if let victim = existing.keys.sorted().first {
                SystemMemoryStore.set(key: victim, value: fact, category: category)
                SemanticMemory.remember(fact, kind: "profile")
                return
            }
        }
        SystemMemoryStore.set(key: namespaced, value: fact, category: category)
        // Mirror into semantic memory so it can be recalled by meaning, not just listed.
        SemanticMemory.remember(fact, kind: "profile")
    }

    /// A compact one-line-per-fact summary for prompt injection, or `nil` when empty.
    static func summary() -> String? {
        let facts = SystemMemoryStore.list(category: category)
        guard !facts.isEmpty else { return nil }
        return facts.values.sorted().prefix(maxFacts).map { "- \($0)" }.joined(separator: "\n")
    }
}
