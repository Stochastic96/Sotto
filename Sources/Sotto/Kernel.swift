import AppKit
import Foundation
import SottoCore

// MARK: - Kernel
//
// The microkernel scheduler. It consults the CapabilityRegistry for the cheapest
// capable path for an intent and, when that path is a pure-Swift *reflex*, executes
// it directly — no Foundation Models session, no tokens, no model load.
//
// Anything that needs a higher tier (Apple Intelligence) returns nil so
// the caller falls through to the existing AI pipeline unchanged. The kernel never
// "downgrades" an AI-tier intent into a guess; it only short-circuits work it can
// prove is a reflex.
//
//   let reply = await Kernel.shared.dispatch("open xcode")   // → "Opening Xcode." (0 tokens)
//   let reply = await Kernel.shared.dispatch("write me a poem") // → nil (escalate to model)

actor Kernel {
    static let shared = Kernel()

    struct Decision: Sendable {
        let capability: CapabilityDescriptor
        let tier: AITier
    }

    /// Reflex executors: capability name → closure that performs the action for the
    /// raw utterance and returns a short spoken/HUD line, or nil if it couldn't act
    /// (e.g. "open" matched but the app name didn't resolve — escalate to the model).
    private var reflexes: [String: @Sendable (String) async -> String?] = [:]

    func bindReflex(_ name: String, _ run: @escaping @Sendable (String) async -> String?) {
        reflexes[name] = run
    }

    /// Names of every bound reflex — used by the capability consistency check.
    func boundReflexNames() -> [String] { Array(reflexes.keys) }

    /// Run a specific bound reflex by capability name, skipping registry routing.
    /// Used by JarvisBrain, which has already resolved the intent semantically; the
    /// reflex still re-parses `intent` itself and may decline (nil → escalate).
    func runReflex(named name: String, intent: String) async -> String? {
        guard let run = reflexes[name] else { return nil }
        return await run(intent)
    }

    // MARK: - Routing

    /// The cheapest capable route for `intent`, or nil if nothing in the registry matches.
    func route(_ intent: String) async -> Decision? {
        guard let cap = await CapabilityRegistry.shared.cheapest(for: intent) else { return nil }
        return Decision(capability: cap, tier: cap.tier)
    }

    /// If the cheapest path is a bound reflex, execute it and return its result line.
    /// Returns nil when the intent has no match, needs a higher tier, or has no reflex
    /// binding — in every nil case the caller should fall through to the AI pipeline.
    func dispatch(_ intent: String) async -> String? {
        guard let decision = await route(intent) else { return nil }
        guard decision.tier == .reflex, let run = reflexes[decision.capability.name] else {
            print("[KERNEL] route('\(intent.prefix(40))') → \(decision.capability.name) [\(decision.tier)] — escalating to AI")
            return nil
        }
        guard let result = await run(intent) else {
            print("[KERNEL] reflex \(decision.capability.name) declined '\(intent.prefix(40))' — escalating to AI")
            return nil
        }
        print("[KERNEL] reflex \(decision.capability.name) handled '\(intent.prefix(40))' — 0 tokens")
        return result
    }

    /// Compound dispatch: split the utterance on conjunctions and run *every* clause
    /// through the reflex path. Succeeds only when all clauses are reflexes — otherwise
    /// returns nil so the whole utterance goes to the model intact (never half-executed).
    func dispatchCompound(_ intent: String) async -> String? {
        let clauses = CommandSplitter.clauses(intent)
        guard clauses.count > 1 else { return await dispatch(intent) }

        var results: [String] = []
        for clause in clauses {
            guard let line = await dispatch(clause) else {
                print("[KERNEL] compound aborted at '\(clause.prefix(30))' — escalating whole utterance to AI")
                return nil
            }
            results.append(line)
        }
        return results.joined(separator: " ")
    }

    // MARK: - Reflex bindings
    //
    // Only bind capabilities that aren't already caught upstream by
    // CommandEngine.checkZeroLatencyShortcut (window/media/volume/etc. are). The
    // kernel's non-redundant win is app launch, which the Jarvis pipeline otherwise
    // sends to the model.

    func seedReflexes() {
        // App launch — "open xcode", "launch terminal", "start notes"
        bindReflex("open_app") { intent in
            guard let app = Kernel.appName(from: intent) else { return nil }
            let ok = await MainActor.run { CommandEngine.openApp(named: app) }
            return ok ? "Opening \(app)." : nil
        }

        // Web search — "search for X", "google X", "look up X"
        // Pure Swift: extract query, open google URL. 0 tokens.
        bindReflex("web_search") { intent in
            guard let query = Kernel.searchQuery(from: intent) else { return nil }
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return nil }
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
            return "Searching for \(query)."
        }

        // Spotify play/pause — "play", "resume", "open Spotify and play"
        // "open Spotify" alone hits this binding because media_play (5 ms) beats open_app
        // (80 ms) when the utterance contains "spotify". Handle both cases here so the
        // compound "open Spotify and play song" resolves entirely at reflex tier (0 tokens).
        bindReflex("media_play") { intent in
            let lower = intent.lowercased()
            // "open/launch Spotify" → just open the app, don't force play.
            // Parentheses are critical: without them `&&` binds tighter than `||` and ANY
            // utterance containing "launch" (e.g. "launch my email") would match.
            if (lower.contains("spotify") && lower.contains("open")) ||
               (lower.contains("spotify") && lower.contains("launch")) {
                let ok = await MainActor.run { CommandEngine.openApp(named: "Spotify") }
                return ok ? "Opening Spotify." : nil
            }
            let ok = await MainActor.run { SpotifyControl.play() }
            return ok ? "Playing." : SpotifyControl.permissionHint
        }

        // Spotify next — "next song", "skip", "skip track"
        bindReflex("media_next") { _ in
            let ok = await MainActor.run { SpotifyControl.next() }
            return ok ? "Skipped to next track." : SpotifyControl.permissionHint
        }

        // Spotify previous — "previous song", "back", "go back"
        bindReflex("media_prev") { _ in
            let ok = await MainActor.run { SpotifyControl.previous() }
            return ok ? "Back to previous track." : SpotifyControl.permissionHint
        }

        // Spotlight file search — "find file X", "where is X", "locate X"
        // Uses mdfind, returns top 3 names. 0 tokens, ~50 ms.
        // Process.waitUntilExit() is blocking, so we offload to a global queue to avoid
        // starving the Swift cooperative thread pool.
        bindReflex("spotlight_search_files") { intent in
            guard let query = Kernel.fileQuery(from: intent) else { return nil }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process(), pipe = Pipe()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                    p.arguments = ["-name", query]
                    p.standardOutput = pipe
                    p.standardError = Pipe()
                    guard (try? p.run()) != nil else { continuation.resume(returning: nil); return }
                    p.waitUntilExit()
                    let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let names = raw.components(separatedBy: "\n")
                        .filter { !$0.isEmpty }
                        .prefix(3)
                        .map { URL(fileURLWithPath: $0).lastPathComponent }
                    continuation.resume(returning: names.isEmpty ? nil : "Found: \(names.joined(separator: ", "))")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Strips a leading launch verb from an "open/launch/start X" utterance and
    /// returns the app name, or nil if no app name remains.
    nonisolated static func appName(from intent: String) -> String? {
        var s = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        for verb in ["open up ", "open ", "launch ", "start ", "run "] {
            if lower.hasPrefix(verb) {
                s = String(s.dropFirst(verb.count))
                break
            }
        }
        // Drop a trailing "app"/"application" and punctuation: "open the notes app" → "the notes"
        var name = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = name.last, ".,!?".contains(last) { name.removeLast() }
        for tail in [" app", " application"] where name.lowercased().hasSuffix(tail) {
            name = String(name.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        }
        if name.lowercased().hasPrefix("the ") { name = String(name.dropFirst(4)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Extracts a web search query from utterances like "search for X", "google X".
    nonisolated static func searchQuery(from intent: String) -> String? {
        var s = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        for verb in ["search the web for ", "search for ", "search ", "google ",
                     "look up ", "look for ", "find information on ", "find info on "] {
            if lower.hasPrefix(verb) { s = String(s.dropFirst(verb.count)); break }
        }
        while let last = s.last, ".,!?".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Must be meaningfully different from the trigger verb alone
        return s.isEmpty || s.count < 2 ? nil : s
    }

    /// Extracts a filename/query from utterances like "find file X", "where is X".
    nonisolated static func fileQuery(from intent: String) -> String? {
        var s = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        for verb in ["find file ", "find document ", "locate file ", "where is ",
                     "locate ", "find "] {
            if lower.hasPrefix(verb) { s = String(s.dropFirst(verb.count)); break }
        }
        while let last = s.last, ".,!?".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
