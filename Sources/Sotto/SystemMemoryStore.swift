import Foundation

struct MemoryItem: Codable {
    let key: String
    let value: String
    let category: String
    let updatedAt: Date
}

enum SystemMemoryStore {
    private static let dbURL: URL = {
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home + "/Projects/Sotto/sotto-data/jarvis_memory.json")
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
