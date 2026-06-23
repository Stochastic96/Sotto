import Foundation

/// Bridges Jarvis to the rest of your apps through the macOS Shortcuts engine. A Shortcut can
/// drive Weather, Home, Music, Maps, Messages — basically any app that ships App Intents — so
/// this is the native, supported "handshake" with other apps (a third-party app can't call
/// another app's intents directly, but it CAN run a Shortcut that does). Uses /usr/bin/shortcuts.
enum ShortcutRunner {

    /// Names of the user's installed Shortcuts.
    static func list() -> String {
        print("[SHORTCUT] list")
        let out = runProcess(["/usr/bin/shortcuts", "list"])
        let names = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.isEmpty ? "No Shortcuts are installed." : "Available Shortcuts:\n\(names)"
    }

    /// Run a Shortcut by name, optionally passing text input; returns its output (or an error).
    static func run(name: String, input: String?) -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return "I need the name of a Shortcut to run." }
        print("[SHORTCUT] run '\(cleanName)'\(input?.isEmpty == false ? " (with input)" : "")")

        let tmp = FileManager.default.temporaryDirectory
        let outputURL = tmp.appendingPathComponent("sc_out_\(UUID().uuidString)")
        var args = ["/usr/bin/shortcuts", "run", cleanName]

        var inputURL: URL?
        if let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let u = tmp.appendingPathComponent("sc_in_\(UUID().uuidString).txt")
            try? input.write(to: u, atomically: true, encoding: .utf8)
            inputURL = u
            args += ["--input-path", u.path]
        }
        args += ["--output-path", outputURL.path]

        let stderr = runProcess(args)
        defer {
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            try? FileManager.default.removeItem(at: outputURL)
        }

        let result = ((try? String(contentsOf: outputURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty { return "Ran '\(cleanName)'. Result: \(result)" }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return "Shortcut '\(cleanName)': \(err)" }
        return "Ran '\(cleanName)'."
    }

    private static func runProcess(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Couldn't run shortcuts: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
