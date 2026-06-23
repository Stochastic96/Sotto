import Foundation

/// One inbox message, as much as Jarvis needs to decide whether it's promotional.
public struct MailMessage {
    public let id: Int
    public let sender: String
    public let subject: String
}

/// Native, on-device bridge to Mail.app via AppleScript (no API keys, no network at our
/// layer). Used by `LongTaskEngine` to process the inbox in small batches. `moveToTrash`
/// uses Mail's `delete`, which moves a message to the Trash mailbox — recoverable, never a
/// permanent purge — so a misclassification is safe to undo.
public enum MailConnector {

    /// Runs an AppleScript source string and returns its text result (`nil` on error).
    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error = error {
            print("[MAIL] AppleScript error: \(error)")
            return nil
        }
        return result.stringValue
    }

    /// Fetch up to `limit` messages from the inbox starting at 1-based index `offset+1`.
    /// Returns an empty array when the window is past the end of the inbox.
    public static func fetchInboxBatch(offset: Int, limit: Int) -> [MailMessage] {
        let start = offset + 1
        let end = offset + limit
        let source = """
        tell application "Mail"
            set output to ""
            set theMessages to messages of inbox
            set n to count of theMessages
            repeat with i from \(start) to \(end)
                if i > n then exit repeat
                set m to item i of theMessages
                try
                    set output to output & (id of m as string) & tab & (sender of m) & tab & (subject of m) & linefeed
                end try
            end repeat
            return output
        end tell
        """
        guard let raw = runScript(source) else { return [] }
        var messages: [MailMessage] = []
        for line in raw.split(separator: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, let id = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            messages.append(MailMessage(id: id, sender: parts[1], subject: parts[2]))
        }
        return messages
    }

    /// Move the given message IDs to the Trash. Returns how many were trashed.
    @discardableResult
    public static func moveToTrash(ids: [Int]) -> Int {
        guard !ids.isEmpty else { return 0 }
        var trashed = 0
        for id in ids {
            let source = """
            tell application "Mail"
                try
                    set m to first message of inbox whose id is \(id)
                    delete m
                    return "ok"
                end try
                return "miss"
            end tell
            """
            if runScript(source) == "ok" { trashed += 1 }
        }
        return trashed
    }

    /// Fast, high-precision heuristic: is this message obviously promotional/marketing?
    /// Used as the fallback classifier when the on-device model isn't available.
    public static func looksPromotional(_ m: MailMessage) -> Bool {
        let hay = (m.sender + " " + m.subject).lowercased()
        let markers = [
            "unsubscribe", "newsletter", "% off", "sale", "deal", "deals", "promo",
            "promotion", "limited time", "offer", "coupon", "discount", "save now",
            "shop now", "black friday", "cyber monday", "flash sale", "exclusive offer",
            "no-reply", "noreply", "marketing", "special offer",
        ]
        return markers.contains { hay.contains($0) }
    }
}
