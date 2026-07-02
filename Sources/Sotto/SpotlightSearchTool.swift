import Foundation
import AppKit
import FoundationModels

// SpotlightSearchTool — instant file/app/document search via macOS Spotlight
// (mdfind CLI). Zero tokens, zero AI calls — results in ~50 ms.

// ── Shared process helper ─────────────────────────────────────────────────

private func runProcess(_ launchPath: String, _ args: [String]) -> String {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = Pipe()  // suppress errors
    try? p.run()
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

// ── SpotlightSearchTool ───────────────────────────────────────────────────

struct SpotlightSearchTool: Tool {
    let name = "spotlight_search_files"
    let description = "Search for files, apps, or documents on this Mac using macOS Spotlight (mdfind). Returns a list of matching file paths instantly — no AI guessing needed."

    @Generable
    struct Arguments {
        @Guide(description: "Search query for Spotlight, e.g. 'project.swift' or 'invoice 2024'")
        let query: String
        @Guide(description: "Max results to return, default 10")
        let limit: String
    }

    func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Error: query must not be empty."
        }

        // Parse limit, cap at 10
        let rawLimit = arguments.limit.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(Int(rawLimit) ?? 10, 10)

        // Try filename-only search first; it's faster and more precise.
        // Fall back to full-text/metadata search if -name returns nothing.
        var raw = runProcess("/usr/bin/mdfind", ["-name", query])
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = runProcess("/usr/bin/mdfind", [query])
        }

        let paths = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paths.isEmpty else {
            return "No files found for: \(query)"
        }

        let capped = Array(paths.prefix(limit))
        let lines  = capped.map { "- \($0)" }.joined(separator: "\n")
        return "Found \(capped.count) file\(capped.count == 1 ? "" : "s"):\n\(lines)"
    }
}

