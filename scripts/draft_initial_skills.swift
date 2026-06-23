import Foundation

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let sottoDataURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Sotto/sotto-data")
let baseDir = sottoDataURL.appendingPathComponent("skills/jarvis")
let manifestURL = baseDir.appendingPathComponent("skills.json")
let scriptsDir = baseDir.appendingPathComponent("scripts")

struct DraftedSkill: Codable {
    let name: String
    let description: String
    let trigger: String
    let language: String
    let body: String
    let createdAt: String
    var enabled: Bool
}

do {
    try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
    
    var skills: [DraftedSkill] = []
    
    // Skill 1: Clean Desktop Screenshots
    skills.append(DraftedSkill(
        name: "clean_screenshots",
        description: "Move desktop screenshots older than 1 day to an archive folder on the desktop to keep it clean.",
        trigger: "clean desktop screenshots",
        language: "shell",
        body: """
        #!/bin/bash
        ARCHIVE_DIR="$HOME/Desktop/Screenshots Archive"
        mkdir -p "$ARCHIVE_DIR"
        find "$HOME/Desktop" -maxdepth 1 -name "Screenshot *.png" -mtime +1 -exec mv {} "$ARCHIVE_DIR/" \\;
        echo "Done archiving old screenshots into '$ARCHIVE_DIR'."
        """,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        enabled: false
    ))
    
    // Skill 2: System Health Check
    skills.append(DraftedSkill(
        name: "system_health",
        description: "Check CPU hogs, battery status, and disk space usage.",
        trigger: "check system health",
        language: "shell",
        body: """
        #!/bin/bash
        echo "=== TOP CPU HOGS ==="
        ps -Ao pcpu,comm -r | head -n 4
        echo ""
        echo "=== DISK SPACE USAGE ==="
        df -h / | tail -n 1
        echo ""
        echo "=== BATTERY STATUS ==="
        pmset -g batt | grep -v "Currently drawing"
        """,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        enabled: false
    ))
    
    // Skill 3: Empty Trash and Clear Cache
    skills.append(DraftedSkill(
        name: "empty_trash",
        description: "Clean up macOS Trash and notify the user when done.",
        trigger: "empty my trash",
        language: "applescript",
        body: """
        tell application "Finder"
            if (count of items in trash) > 0 then
                empty trash
                display notification "Trash has been emptied successfully." with title "Sotto Cleanup"
            else
                display notification "Trash is already empty." with title "Sotto Cleanup"
            end if
        end tell
        """,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        enabled: false
    ))
    
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let data = try encoder.encode(skills)
    try data.write(to: manifestURL)
    
    print("Successfully drafted 3 initial skills into: \\(manifestURL.path)")
} catch {
    print("Error drafting skills: \\(error)")
}
