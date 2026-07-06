import Foundation
import os
import CoreSpotlight

/// A skill Jarvis drafted for itself. Drafts are saved DISABLED — generation is
/// autonomous, but execution waits until the user says "enable skill <name>".
struct DraftedSkill: Codable {
    let name: String
    let description: String
    let trigger: String       // spoken phrase that should invoke it
    let language: String      // "shell" or "applescript"
    let body: String
    let createdAt: String
    var enabled: Bool
}

/// Autonomous skill synthesis with a user-only approval gate.
///
/// - Jarvis (the agent) can `draft` new skills at any time → stored DISABLED.
/// - Only the USER, by speaking "enable skill <name>", can flip one on (`enable`).
/// - `runEnabled` refuses to execute anything not enabled.
///
/// This is the safe shape of "write scripts in the background": creating is cheap and
/// reversible; running unreviewed self-written code is not, so it's gated.
enum SkillStore {
    private static let lock = OSAllocatedUnfairLock<Void>()

    private static var baseDir: URL {
        SettingsController.sottoDataURL.appendingPathComponent("skills/jarvis")
    }
    private static var manifestURL: URL { baseDir.appendingPathComponent("skills.json") }
    private static var scriptsDir: URL { baseDir.appendingPathComponent("scripts") }

    private static func ensureDirs() {
        try? FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
    }

    private static func load() -> [DraftedSkill] {
        // A missing manifest is normal on first run — return empty quietly. Only a manifest
        // that exists but can't be read/decoded is an error worth surfacing.
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode([DraftedSkill].self, from: data)
        } catch {
            print("[SKILLS] Failed to load skills manifest (\(error.localizedDescription)); treating as empty.")
            return []
        }
    }

    private static func save(_ skills: [DraftedSkill]) {
        ensureDirs()
        do {
            let data = try JSONEncoder().encode(skills)
            try data.write(to: manifestURL)
        } catch {
            print("[SKILLS] Failed to save skills manifest (\(error.localizedDescription)) — drafts may not persist.")
        }
    }

    private static func slug(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    // MARK: - Autonomous (agent-callable)

    /// Draft a new skill. Always saved DISABLED. Returns a confirmation string.
    @discardableResult
    static func draft(name: String, description: String, trigger: String, language: String, body: String) -> String {
        let lang: String
        if language.lowercased().contains("apple") {
            lang = "applescript"
        } else if language.lowercased().contains("swift") {
            lang = "swift"
        } else {
            lang = "shell"
        }
        let skill = DraftedSkill(
            name: slug(name),
            description: description,
            trigger: trigger,
            language: lang,
            body: body,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            enabled: false
        )
        lock.withLock {
            var skills = load()
            skills.removeAll { $0.name == skill.name }   // overwrite a prior draft of same name
            skills.append(skill)
            save(skills)
        }
        indexInSpotlight(skill: skill)
        return "Drafted skill '\(skill.name)' (\(lang)), disabled. Say \"enable skill \(skill.name)\" to activate it."
    }

    /// All drafts (enabled + pending), newest last.
    static func listAll() -> [DraftedSkill] {
        lock.withLock { load() }
    }

    /// Human-readable list of pending (disabled) drafts, for recall/summaries.
    static func pendingSummary() -> String {
        let pending = listAll().filter { !$0.enabled }
        guard !pending.isEmpty else { return "No skills are waiting for approval." }
        let lines = pending.map { "• \($0.name): \($0.description) (trigger: \"\($0.trigger)\")" }
        return "Skills I drafted and are waiting for your approval:\n" + lines.joined(separator: "\n")
    }

    // MARK: - User-only approval

    /// Enable a drafted skill by (slugged) name and write its script file. USER-ONLY.
    static func enable(_ rawName: String) -> String {
        let target = slug(rawName)
        let skill: DraftedSkill? = lock.withLock {
            var skills = load()
            guard let idx = skills.firstIndex(where: { $0.name == target }) else { return nil }
            skills[idx].enabled = true
            save(skills)
            return skills[idx]
        }
        guard let skill else {
            return "No drafted skill named '\(target)'."
        }
        indexInSpotlight(skill: skill)

        // Materialize the script on disk for transparency / inspection.
        ensureDirs()
        let ext: String
        if skill.language == "applescript" {
            ext = "applescript"
        } else if skill.language == "swift" {
            ext = "swift"
        } else {
            ext = "sh"
        }
        let fileURL = scriptsDir.appendingPathComponent("\(target).\(ext)")
        do {
            try skill.body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("[SKILLS] Failed to write script file for '\(target)' (\(error.localizedDescription)).")
        }

        // Compile Swift skills in the background — swiftc takes seconds on the M1 and
        // enable() runs on the MainActor Jarvis pipeline, so the compile must never block
        // the caller. Until the binary lands, runEnabled() interprets the .swift source;
        // the compiler writes to a temp path and the finished binary is swapped in with a
        // rename so a run can never execute a half-written executable.
        if skill.language == "swift" {
            let binURL = scriptsDir.appendingPathComponent(target)
            let tmpURL = scriptsDir.appendingPathComponent(".\(target).compiling")
            Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
                process.arguments = ["-O", "-o", tmpURL.path, fileURL.path]
                let status: Int32
                do {
                    status = try await withCheckedThrowingContinuation { continuation in
                        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                        do { try process.run() } catch { continuation.resume(throwing: error) }
                    }
                } catch {
                    print("[SKILLS] Pre-compilation execution error for '\(target)': \(error.localizedDescription)")
                    return
                }
                if status == 0 {
                    do {
                        try? FileManager.default.removeItem(at: binURL)
                        try FileManager.default.moveItem(at: tmpURL, to: binURL)
                        print("[SKILLS] Pre-compiled '\(target)' successfully.")
                    } catch {
                        print("[SKILLS] Could not install compiled binary for '\(target)': \(error.localizedDescription)")
                    }
                } else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    print("[SKILLS] Pre-compilation of '\(target)' failed with exit code \(status)")
                }
            }
        }

        // Register the skill trigger dynamically with CommandEngine so it can run zero-latency
        CommandEngine.registerSkillTrigger(skill.trigger, skillName: skill.name)

        return "Enabled skill '\(target)'. Jarvis can now run it."
    }

    static func isEnabled(_ rawName: String) -> Bool {
        listAll().first { $0.name == slug(rawName) }?.enabled ?? false
    }

    // MARK: - Gated execution

    /// Run an ENABLED skill by name. Refuses anything not approved by the user.
    static func runEnabled(_ rawName: String) async -> String {
        let target = slug(rawName)
        let skill = lock.withLock { load().first { $0.name == target } }

        guard let skill else { return "No skill named '\(target)'." }
        guard skill.enabled else {
            return "Skill '\(target)' is not enabled yet. Ask the user to say \"enable skill \(target)\" first."
        }

        // INTERCEPT SOTTO NATIVE TOOL CALL REFLEXES
        if skill.body.hasPrefix("# SOTTO_TOOL_CALL: ") {
            let line = skill.body.components(separatedBy: "\n").first ?? ""
            let prefixLen = "# SOTTO_TOOL_CALL: ".count
            let payload = String(line.dropFirst(prefixLen))
            
            // Format: toolName:jsonArgs
            if let firstBraceIdx = payload.firstIndex(of: "{") {
                let toolName = String(payload[..<firstBraceIdx]).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
                let jsonArgs = String(payload[firstBraceIdx...])
                
                do {
                    return try await JarvisToolbox.callToolNatively(name: toolName, jsonArgs: jsonArgs)
                } catch {
                    return "Reflex failed: \(error.localizedDescription)"
                }
            }
        }

        ensureDirs()
        let ext: String
        if skill.language == "applescript" {
            ext = "applescript"
        } else if skill.language == "swift" {
            ext = "swift"
        } else {
            ext = "sh"
        }
        let fileURL = scriptsDir.appendingPathComponent("\(target).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try skill.body.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                print("[SKILLS] Failed to materialize script for '\(target)' (\(error.localizedDescription)).")
            }
        }
        
        let command: String
        if skill.language == "applescript" {
            command = "osascript \"\(fileURL.path)\""
        } else if skill.language == "swift" {
            let binURL = scriptsDir.appendingPathComponent(target)
            if FileManager.default.fileExists(atPath: binURL.path) {
                command = "\"\(binURL.path)\""
            } else {
                command = "/usr/bin/swift \"\(fileURL.path)\""
            }
        } else {
            command = "bash \"\(fileURL.path)\""
        }
        return CommandEngine.runCommandNatively(command)
    }

    private static func indexInSpotlight(skill: DraftedSkill) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = "Jarvis Skill: \(skill.name)"
        let status = skill.enabled ? "Enabled" : "Pending Approval"
        attributeSet.contentDescription = "Trigger: \"\(skill.trigger)\" (\(status)) - \(skill.description)"
        
        let item = CSSearchableItem(
            uniqueIdentifier: "sotto:skill:\(skill.name)",
            domainIdentifier: "sotto.skills",
            attributeSet: attributeSet
        )
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error = error {
                print("[SKILLS] CoreSpotlight index error: \(error.localizedDescription)")
            }
        }
    }
}
