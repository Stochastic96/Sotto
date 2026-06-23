import Foundation
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
    private static let lock = NSLock()

    private static var baseDir: URL {
        SettingsController.sottoDataURL.appendingPathComponent("skills/jarvis")
    }
    private static var manifestURL: URL { baseDir.appendingPathComponent("skills.json") }
    private static var scriptsDir: URL { baseDir.appendingPathComponent("scripts") }

    private static func ensureDirs() {
        try? FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
    }

    private static func load() -> [DraftedSkill] {
        guard let data = try? Data(contentsOf: manifestURL),
              let skills = try? JSONDecoder().decode([DraftedSkill].self, from: data) else { return [] }
        return skills
    }

    private static func save(_ skills: [DraftedSkill]) {
        ensureDirs()
        if let data = try? JSONEncoder().encode(skills) {
            try? data.write(to: manifestURL)
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
        lock.lock(); defer { lock.unlock() }
        var skills = load()
        let lang = language.lowercased().contains("apple") ? "applescript" : "shell"
        let skill = DraftedSkill(
            name: slug(name),
            description: description,
            trigger: trigger,
            language: lang,
            body: body,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            enabled: false
        )
        skills.removeAll { $0.name == skill.name }   // overwrite a prior draft of same name
        skills.append(skill)
        save(skills)
        indexInSpotlight(skill: skill)
        return "Drafted skill '\(skill.name)' (\(lang)), disabled. Say \"enable skill \(skill.name)\" to activate it."
    }

    /// All drafts (enabled + pending), newest last.
    static func listAll() -> [DraftedSkill] {
        lock.lock(); defer { lock.unlock() }
        return load()
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
        lock.lock(); defer { lock.unlock() }
        let target = slug(rawName)
        var skills = load()
        guard let idx = skills.firstIndex(where: { $0.name == target }) else {
            return "No drafted skill named '\(target)'."
        }
        skills[idx].enabled = true
        save(skills)
        
        let skill = skills[idx]
        indexInSpotlight(skill: skill)
        
        // Materialize the script on disk for transparency / inspection.
        ensureDirs()
        let ext = skill.language == "applescript" ? "applescript" : "sh"
        let fileURL = scriptsDir.appendingPathComponent("\(target).\(ext)")
        try? skill.body.write(to: fileURL, atomically: true, encoding: .utf8)
        return "Enabled skill '\(target)'. Jarvis can now run it."
    }

    static func isEnabled(_ rawName: String) -> Bool {
        listAll().first { $0.name == slug(rawName) }?.enabled ?? false
    }

    // MARK: - Gated execution

    /// Run an ENABLED skill by name. Refuses anything not approved by the user.
    static func runEnabled(_ rawName: String) -> String {
        lock.lock()
        let target = slug(rawName)
        let skill = load().first { $0.name == target }
        lock.unlock()

        guard let skill else { return "No skill named '\(target)'." }
        guard skill.enabled else {
            return "Skill '\(target)' is not enabled yet. Ask the user to say \"enable skill \(target)\" first."
        }
        ensureDirs()
        let ext = skill.language == "applescript" ? "applescript" : "sh"
        let fileURL = scriptsDir.appendingPathComponent("\(target).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? skill.body.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let command = skill.language == "applescript"
            ? "osascript \"\(fileURL.path)\""
            : "bash \"\(fileURL.path)\""
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
