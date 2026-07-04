import Foundation

/// A thread-safe, in-memory scratchpad cache private to Sotto.
/// This allows Sotto to store, read, and append text notes or intermediate
/// findings in the background without touching or corrupting the user's macOS system clipboard.
public actor SottoMemoryPad {
    public static let shared = SottoMemoryPad()
    private init() {}

    private var content: String = ""

    public func get() -> String {
        return content
    }

    public func set(_ text: String) {
        content = text
        print("[MEMORYPAD] Overwrote pad content (\(text.count) chars)")
    }

    public func append(_ text: String) {
        if content.isEmpty {
            content = text
        } else {
            content += "\n\n" + text
        }
        print("[MEMORYPAD] Appended text to pad (total: \(content.count) chars)")
    }

    public func clear() {
        content = ""
        print("[MEMORYPAD] Cleared pad content")
    }
}
