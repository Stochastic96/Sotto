import Foundation
import AppKit
import FoundationModels

// FileOrganizerTool — tidies ~/Downloads into category subfolders, skipping
// anything less than 1 day old so in-progress downloads aren't displaced.
//
// LargeFileFinderTool — recursively scans a directory (default ~/Downloads)
// and returns the top 10 largest files above a configurable size threshold.
// Scan is capped at 3 levels deep to avoid hanging on large trees.

// ── Shared helpers ────────────────────────────────────────────────────────

// FileManager.default is documented thread-safe; the type itself just isn't
// Sendable-audited by the SDK yet.
nonisolated(unsafe) private let fm = FileManager.default

private func expandPath(_ path: String) -> String {
    if path.hasPrefix("~") {
        return (path as NSString).expandingTildeInPath
    }
    return path
}

// ── FileOrganizerTool ─────────────────────────────────────────────────────

struct FileOrganizerTool: Tool {
    let name = "organize_downloads"
    let description = "Organize ~/Downloads by moving files into subfolders by type: Archives, Images, Documents, Code, Apps, Videos. Skips files less than 1 day old."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let downloadsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

        // Category → extensions mapping
        let categories: [(folder: String, extensions: Set<String>)] = [
            ("Archives",  ["zip", "tar", "gz", "7z", "rar"]),
            ("Images",    ["png", "jpg", "jpeg", "gif", "webp", "heic"]),
            ("Documents", ["pdf", "docx", "doc", "xlsx", "pptx", "pages"]),
            ("Code",      ["swift", "py", "js", "ts", "sh", "rb", "go"]),
            ("Apps",      ["dmg", "pkg", "ipa"]),
            ("Videos",    ["mp4", "mov", "avi", "mkv"]),
        ]

        // Build a reverse lookup: extension → folder name
        var extToFolder: [String: String] = [:]
        for cat in categories {
            for ext in cat.extensions {
                extToFolder[ext] = cat.folder
            }
        }

        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        var counts: [String: Int] = [:]

        // Enumerate only the top-level contents of Downloads (non-recursive)
        guard let items = try? fm.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "Could not read ~/Downloads."
        }

        for itemURL in items {
            // Only move regular files
            guard let resourceValues = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            // Skip files younger than 1 day
            if let created = resourceValues.creationDate, created > oneDayAgo {
                continue
            }

            let ext = itemURL.pathExtension.lowercased()
            guard let folderName = extToFolder[ext] else {
                continue  // unknown extension — leave it alone
            }

            let destFolder = downloadsURL.appendingPathComponent(folderName)

            // Create the subfolder if it doesn't exist
            if !fm.fileExists(atPath: destFolder.path) {
                try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
            }

            let destURL = destFolder.appendingPathComponent(itemURL.lastPathComponent)

            // Avoid overwriting an existing file with the same name
            guard !fm.fileExists(atPath: destURL.path) else {
                continue
            }

            if (try? fm.moveItem(at: itemURL, to: destURL)) != nil {
                counts[folderName, default: 0] += 1
            }
        }

        let total = counts.values.reduce(0, +)
        guard total > 0 else {
            let result = "Downloads is already tidy — nothing to move."
            await EventBus.shared.emit(.missionCompleted(id: "file_organizer", summary: result))
            return result
        }

        // Build human-readable summary
        let parts = categories
            .compactMap { cat -> String? in
                guard let n = counts[cat.folder] else { return nil }
                return "\(n) \(cat.folder.lowercased())"
            }
            .joined(separator: ", ")

        let result = "Organized \(total) file\(total == 1 ? "" : "s"): \(parts)."
        await EventBus.shared.emit(.missionCompleted(id: "file_organizer", summary: result))
        return result
    }
}

// ── LargeFileFinderTool ───────────────────────────────────────────────────

struct LargeFileFinderTool: Tool {
    let name = "find_large_files"
    let description = "Recursively find the largest files in a directory (default ~/Downloads). Returns the top 10 files above a configurable size threshold."

    @Generable
    struct Arguments {
        @Guide(description: "Directory path to scan. Defaults to ~/Downloads if empty.")
        let location: String
        @Guide(description: "Minimum file size in megabytes to report. Defaults to 100 if empty.")
        let minSizeMB: String
    }

    func call(arguments: Arguments) async throws -> String {
        // Resolve location
        let rawPath = arguments.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPath = rawPath.isEmpty ? "\(NSHomeDirectory())/Downloads" : expandPath(rawPath)
        let rootURL  = URL(fileURLWithPath: rootPath)

        // Resolve minimum size
        let rawSize = arguments.minSizeMB.trimmingCharacters(in: .whitespacesAndNewlines)
        let minBytes = Int64((Double(rawSize) ?? 100.0) * 1_048_576)

        // Enumerate up to 3 levels deep
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return "Cannot enumerate \(rootPath)."
        }

        struct FileStat {
            let url: URL
            let bytes: Int64
        }

        var found: [FileStat] = []
        let maxDepth = 3
        let rootComponents = rootURL.pathComponents.count

        while let fileURL = enumerator.nextObject() as? URL {
            // Enforce depth cap
            let depth = fileURL.pathComponents.count - rootComponents
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  rv.isRegularFile == true,
                  let size = rv.fileSize else {
                continue
            }

            let bytes = Int64(size)
            if bytes >= minBytes {
                found.append(FileStat(url: fileURL, bytes: bytes))
            }
        }

        guard !found.isEmpty else {
            return "No files larger than \(rawSize.isEmpty ? "100" : rawSize) MB found in \(rootPath)."
        }

        // Sort descending, take top 10
        let top10 = found.sorted { $0.bytes > $1.bytes }.prefix(10)

        let lines = top10.map { stat -> String in
            let mb = String(format: "%.1f", Double(stat.bytes) / 1_048_576)
            return "\(stat.url.lastPathComponent) (\(mb) MB)"
        }

        return lines.joined(separator: "\n")
    }
}
