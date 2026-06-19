import Foundation
import AppKit
#if canImport(FoundationModels)
import FoundationModels

// Native Apple Foundation Models tools. Each wraps an existing Sotto skill
// (an AppleScript in sotto-data/skills/ or a native SystemControlHelper call) so the
// on-device model can decide WHICH micro-task to run and with WHAT arguments — no
// brittle JSON-plan + repair step. The framework injects each tool's schema into the
// prompt and calls `call(arguments:)` when the model picks it.
//
// Design notes for speed:
// - `call` is off-MainActor (the Tool protocol's requirement is @concurrent), so the
//   blocking Process/AppleScript work here never stalls the UI.
// - Tools return a short result string; the model summarizes it into one spoken line.

@available(macOS 26.0, *)
private func shellEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

/// What to do with Spotify. A constrained `@Generable` enum means guided generation can
/// ONLY return one of these cases — the model can't invent "resume"/"skip"/"back" and
/// fall through to a wrong branch, which is how the old single-String action misfired.
@available(macOS 26.0, *)
@Generable
enum SpotifyAction {
    case play, pause, next, previous, playSong
}

/// Control Spotify specifically (never Apple Music): play, pause, skip, or play a song.
@available(macOS 26.0, *)
struct SpotifyTool: Tool {
    let name = "control_spotify"
    let description = "Control Spotify ONLY (not Apple Music): play, pause, skip tracks, or search and play a specific song or artist."

    @Generable
    struct Arguments {
        @Guide(description: "What to do with Spotify.")
        let action: SpotifyAction
        @Guide(description: "The song or artist to search for. REQUIRED only when action is playSong; leave empty otherwise.")
        let query: String?
    }

    func call(arguments: Arguments) async throws -> String {
        // Every command is addressed to Spotify by name (see SpotifyControl), so it can
        // never accidentally drive Apple Music or another player.
        switch arguments.action {
        case .play:     await SpotifyControl.play();     return "Spotify playing."
        case .pause:    await SpotifyControl.pause();    return "Spotify paused."
        case .next:     await SpotifyControl.next();     return "Skipped to the next track."
        case .previous: await SpotifyControl.previous(); return "Back to the previous track."
        case .playSong:
            let q = (arguments.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return "Tell me which song or artist to play." }
            return await SpotifyControl.searchAndPlay(q)
        }
    }
}

/// Set system output volume (0–100), or mute/unmute. Native — instant, no AppleScript.
@available(macOS 26.0, *)
struct VolumeTool: Tool {
    let name = "set_volume"
    let description = "Set the Mac's output volume or mute/unmute the speakers."

    @Generable
    struct Arguments {
        @Guide(description: "A volume percentage from 0 to 100, or the word 'mute' or 'unmute'.")
        let level: String
    }

    func call(arguments: Arguments) async throws -> String {
        let v = arguments.level.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch v {
        case "mute":
            _ = SystemControlHelper.setMuted(true);  return "Muted."
        case "unmute":
            _ = SystemControlHelper.setMuted(false); return "Unmuted."
        default:
            if let pct = Float(v.replacingOccurrences(of: "%", with: "")) {
                _ = SystemControlHelper.setVolume(max(0, min(100, pct)))
                return "Volume set to \(Int(pct))%."
            }
            return "Could not parse volume '\(arguments.level)'."
        }
    }
}

/// Nudge screen brightness up or down. Native — instant.
@available(macOS 26.0, *)
struct BrightnessTool: Tool {
    let name = "adjust_brightness"
    let description = "Increase or decrease the screen brightness."

    @Generable
    struct Arguments {
        @Guide(description: "Either 'up' or 'down'.")
        let direction: String
    }

    func call(arguments: Arguments) async throws -> String {
        let current = SystemControlHelper.getBrightness()
        let up = arguments.direction.lowercased().contains("up")
        _ = SystemControlHelper.setBrightness(max(0, min(1, current + (up ? 0.15 : -0.15))))
        return up ? "Brightness up." : "Brightness down."
    }
}

/// Open a URL in Chrome.
@available(macOS 26.0, *)
struct OpenWebsiteTool: Tool {
    let name = "open_website"
    let description = "Open a website URL in the browser."

    @Generable
    struct Arguments {
        @Guide(description: "A full URL, e.g. https://youtube.com")
        let url: String
    }

    func call(arguments: Arguments) async throws -> String {
        var url = arguments.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.lowercased().hasPrefix("http") { url = "https://" + url }
        // Pure in-process Swift — opens instantly in the default browser, no AppleScript
        // file read, no subprocess.
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        return "Opened \(url)."
    }
}

/// Launch a macOS application by name.
@available(macOS 26.0, *)
struct OpenAppTool: Tool {
    let name = "open_app"
    let description = "Launch a macOS application by name (e.g. Notes, Spotify, Safari)."

    @Generable
    struct Arguments {
        @Guide(description: "The application name, e.g. 'Notes' or 'Visual Studio Code'.")
        let appName: String
    }

    func call(arguments: Arguments) async throws -> String {
        let appName = arguments.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = "/Applications/\(appName).app"
        let sysPath = "/System/Applications/\(appName).app"
        let utilPath = "/System/Applications/Utilities/\(appName).app"
        
        var targetURL: URL? = nil
        for p in [path, sysPath, utilPath] {
            if FileManager.default.fileExists(atPath: p) {
                targetURL = URL(fileURLWithPath: p)
                break
            }
        }
        
        if targetURL == nil {
            let commonIDs = ["com.apple.\(appName.lowercased())", "com.google.\(appName)", "com.apple.Utilities.\(appName)"]
            for bid in commonIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    targetURL = url
                    break
                }
            }
        }
        
        if let appURL = targetURL {
            do {
                try await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                return "Opened \(appName)."
            } catch {
                return "Failed to open \(appName) natively: \(error.localizedDescription)"
            }
        } else {
            let process = Process()
            process.launchPath = "/usr/bin/open"
            process.arguments = ["-a", appName]
            do {
                try process.run()
                return "Opened \(appName) via open fallback."
            } catch {
                return "Failed to open \(appName) via fallback: \(error.localizedDescription)"
            }
        }
    }
}

/// Create a note in Apple Notes.
@available(macOS 26.0, *)
struct CreateNoteTool: Tool {
    let name = "create_note"
    let description = "Create a note in Apple Notes with the given content."

    @Generable
    struct Arguments {
        @Guide(description: "The note's text content.")
        let content: String
    }

    func call(arguments: Arguments) async throws -> String {
        let c = arguments.content
        let ok = NativeSystemOrchestrator.createNote(c)
        return ok ? "Note saved." : "Could not save the note."
    }
}

/// Web search in the browser.
@available(macOS 26.0, *)
struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for a query and open the results in the browser."

    @Generable
    struct Arguments {
        @Guide(description: "The search query.")
        let query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let q = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pure in-process Swift — build the URL and open it instantly.
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        if let u = URL(string: "https://www.google.com/search?q=\(encoded)") { NSWorkspace.shared.open(u) }
        return "Searching the web for \(q)."
    }
}

/// Read what's currently on screen (native Vision OCR). This is the model's "eyes":
/// after opening/searching, it calls this to SEE the page, then decides the next step
/// (which link to click, whether a login is needed, etc.) — true multi-step handling.
@available(macOS 26.0, *)
struct ReadScreenTool: Tool {
    let name = "read_screen"
    let description = "Read the text currently visible on screen using OCR. Call this to see the page/app before deciding the next action (e.g. after a search, to find a link or button to click)."

    @Generable
    struct Arguments {
        @Guide(description: "What you are looking for on screen, e.g. 'first search result' or 'login button'. Used only as a hint.")
        let lookingFor: String
    }

    func call(arguments: Arguments) async throws -> String {
        let text = CommandEngine.ocrScreen()
        if text.isEmpty { return "The screen has no readable text right now." }
        // Cap the returned text so a busy page can't blow the ~4k-token context window.
        let capped = text.count > 1500 ? String(text.prefix(1500)) + "…" : text
        return "Screen text (looking for \(arguments.lookingFor)):\n\(capped)"
    }
}

/// Click an on-screen element by its visible text/label (uses OCR + a synthetic click).
/// Lets the agent press "first result", "Sign in", "Allow", etc. as a single step.
@available(macOS 26.0, *)
struct ClickElementTool: Tool {
    let name = "click_element"
    let description = "Click an on-screen button, link, or label by its visible text. Use after read_screen to act on what you saw."

    @Generable
    struct Arguments {
        @Guide(description: "The exact visible text of the button/link to click, e.g. 'Sign in' or the result's title.")
        let label: String
    }

    func call(arguments: Arguments) async throws -> String {
        let clicked = await CommandEngine.findAndClickText(arguments.label)
        return clicked ? "Clicked '\(arguments.label)'." : "Couldn't find '\(arguments.label)' on screen."
    }
}

/// Draft a NEW reusable skill (autonomous learning). Always saved DISABLED — the user
/// must say "enable skill <name>" before it can run. Use when you notice a repeated
/// multi-step task worth turning into a one-shot shortcut.
@available(macOS 26.0, *)
struct DraftSkillTool: Tool {
    let name = "draft_skill"
    let description = "Save a new reusable skill (a shell or AppleScript snippet) for a task the user does often. It is saved disabled and only runs after the user approves it."

    @Generable
    struct Arguments {
        @Guide(description: "Short skill name, e.g. 'open_work_apps'.")
        let name: String
        @Guide(description: "One line describing what the skill does.")
        let description: String
        @Guide(description: "The spoken phrase that should trigger it, e.g. 'start my work setup'.")
        let trigger: String
        @Guide(description: "Either 'shell' or 'applescript'.")
        let language: String
        @Guide(description: "The actual script body to run.")
        let body: String
    }

    func call(arguments: Arguments) async throws -> String {
        SkillStore.draft(name: arguments.name, description: arguments.description,
                         trigger: arguments.trigger, language: arguments.language, body: arguments.body)
    }
}

/// Run a skill the user has already ENABLED. Refuses anything not approved.
@available(macOS 26.0, *)
struct RunSkillTool: Tool {
    let name = "run_skill"
    let description = "Run a previously enabled custom skill by name. Only enabled skills will run."

    @Generable
    struct Arguments {
        @Guide(description: "The skill name to run.")
        let name: String
    }

    func call(arguments: Arguments) async throws -> String {
        let out = SkillStore.runEnabled(arguments.name)
        return out.isEmpty ? "Ran '\(arguments.name)'." : out
    }
}

/// Recall what Jarvis has done recently and which skills await approval — so it can
/// answer "what did you do today?" / "what have you learned?".
@available(macOS 26.0, *)
struct RecallHistoryTool: Tool {
    let name = "recall_history"
    let description = "Look up Jarvis's recent activity log and any skills awaiting approval, so you can summarize what was done or learned."

    @Generable
    struct Arguments {
        @Guide(description: "How many recent actions to consider (default 20).")
        let limit: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let n = arguments.limit > 0 ? arguments.limit : 20
        return "Recent activity:\n\(TaskJournal.recent(limit: n))\n\n\(SkillStore.pendingSummary())"
    }
}

/// System Status diagnostics (battery, Wifi, disk space)
@available(macOS 26.0, *)
struct SystemStatusTool: Tool {
    let name = "get_system_status"
    let description = "Get the Mac's system health status, including battery level, Wi-Fi SSID connection, and free disk space."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let battery = SystemDiagnostics.getBatteryPercentage()
        let wifi = SystemDiagnostics.getWifiSSID()
        let disk = SystemDiagnostics.getFreeDiskSpace()
        return "Battery: \(battery), Wi-Fi: \(wifi), Free Disk Space: \(disk)."
    }
}

/// RAM Memory diagnostics
@available(macOS 26.0, *)
struct RAMMemoryStatusTool: Tool {
    let name = "get_ram_status"
    let description = "Get the Mac's RAM memory consumption details, and top memory consumers."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let ram = SystemDiagnostics.getRAMUsage()
        let hogs = SystemDiagnostics.getTopMemoryProcesses()
        return "Total RAM: \(String(format: "%.2f", ram.totalGB)) GB, Free: \(String(format: "%.2f", ram.freeGB)) GB, Used Percent: \(String(format: "%.1f", ram.usedPercent))%. Top consumers:\n\(hogs)"
    }
}

/// geocode locations using Nominatim / OpenStreetMap
@available(macOS 26.0, *)
struct LocationGeocoderTool: Tool {
    let name = "geocode_location"
    let description = "Geocode a location or place name to find its coordinates, address, and display it in Google Maps."

    @Generable
    struct Arguments {
        @Guide(description: "The name of the place, e.g. Eiffel Tower or Delhi.")
        let placeName: String
    }

    func call(arguments: Arguments) async throws -> String {
        let cleanPlace = arguments.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPlace.isEmpty { return "Place name cannot be empty." }
        
        if let result = await SystemDiagnostics.geocodeLocation(placeName: cleanPlace) {
            let mapsUrl = "https://www.google.com/maps/place/\(cleanPlace.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            _ = await MainActor.run {
                NSWorkspace.shared.open(URL(string: mapsUrl)!)
            }
            return "Address: \(result.display_name). Coordinates: \(result.lat), \(result.lon). Opened in Google Maps."
        } else {
            return "Could not geocode '\(cleanPlace)' via Nominatim."
        }
    }
}

/// Wikipedia Search Fact Lookup
@available(macOS 26.0, *)
struct WikipediaLookupTool: Tool {
    let name = "wikipedia_lookup"
    let description = "Search Wikipedia for a query and return a summary extract of the page."

    @Generable
    struct Arguments {
        @Guide(description: "The search query or topic to look up, e.g. Mahatma Gandhi.")
        let query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let cleanQuery = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanQuery.isEmpty { return "Query cannot be empty." }
        
        if let cached = SystemMemoryStore.get(key: "wiki:\(cleanQuery.lowercased())") {
            return "Cached Wikipedia info:\n\(cached)"
        }
        
        if let result = await SystemDiagnostics.queryWikipedia(query: cleanQuery) {
            let combinedVal = "### Wikipedia: \(result.title)\n\(result.extract)\n*(Source: \(result.url))*"
            SystemMemoryStore.set(key: "wiki:\(cleanQuery.lowercased())", value: combinedVal, category: "wikipedia")
            return combinedVal
        } else {
            return "No Wikipedia entry found for '\(cleanQuery)'."
        }
    }
}

/// Persistent memory / active goals
@available(macOS 26.0, *)
struct MemoryGoalTool: Tool {
    let name = "manage_memory_goals"
    let description = "Manage persistent tasks, goals, or settings. Supports setting, getting, or listing keys."

    @Generable
    struct Arguments {
        @Guide(description: "Action: one of 'set', 'get', 'list'")
        let action: String
        @Guide(description: "The key to access, e.g., 'current_task'")
        let key: String
        @Guide(description: "The value to set (required for set action)")
        let value: String?
        @Guide(description: "The category to filter by (optional, e.g., 'active_task')")
        let category: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let act = arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch act {
        case "set":
            guard let val = arguments.value else { return "Value is required for 'set' action." }
            let cat = arguments.category ?? "general"
            SystemMemoryStore.set(key: arguments.key, value: val, category: cat)
            return "Set \(arguments.key) = \(val) in category \(cat)."
        case "get":
            if let val = SystemMemoryStore.get(key: arguments.key) {
                return "Value: \(val)"
            } else {
                return "Key \(arguments.key) not found."
            }
        case "list":
            let cat = arguments.category ?? "active_task"
            let list = SystemMemoryStore.list(category: cat)
            if list.isEmpty { return "No items found in category \(cat)." }
            return list.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        default:
            return "Invalid memory action: \(arguments.action)."
        }
    }
}

/// Send a prompt to the Claude desktop app's quick-entry popover (no full app window).
/// Use for research / questions you want answered in Claude.
@available(macOS 26.0, *)
struct AskClaudeTool: Tool {
    let name = "ask_claude"
    let description = "Send a prompt to the Claude desktop app's quick-entry popover and start a chat there. Use when the user wants Claude to research or answer something."

    @Generable
    struct Arguments {
        @Guide(description: "The full prompt or question to send to Claude.")
        let prompt: String
    }

    @MainActor
    func call(arguments: Arguments) async throws -> String {
        let prompt = arguments.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = await ClaudeQuickEntry.sendAndReadResponse(prompt)
        return "Claude response:\n\(response)"
    }
}

/// Create a reminder natively using EventKit.
@available(macOS 26.0, *)
struct ReminderTool: Tool {
    let name = "create_reminder"
    let description = "Create a reminder in the macOS Reminders app natively. Supports optional due date."

    @Generable
    struct Arguments {
        @Guide(description: "The reminder's title/text.")
        let title: String
        @Guide(description: "Optional ISO8601 due date string, e.g., '2026-06-19T17:00:00+02:00'.")
        let dueDate: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Reminder title cannot be empty." }
        
        var date: Date? = nil
        if let dueStr = arguments.dueDate, !dueStr.isEmpty {
            let formatter = ISO8601DateFormatter()
            date = formatter.date(from: dueStr)
        }
        
        let success = await EventKitOrchestrator.createReminder(title: title, dueDate: date)
        if success {
            return "Reminder '\(title)' successfully created."
        } else {
            return "Failed to create reminder '\(title)'. Ensure permission is granted."
        }
    }
}

/// Create a calendar event natively using EventKit.
@available(macOS 26.0, *)
struct CalendarTool: Tool {
    let name = "create_calendar_event"
    let description = "Create an event/appointment in the default macOS calendar natively."

    @Generable
    struct Arguments {
        @Guide(description: "The event summary or title.")
        let title: String
        @Guide(description: "ISO8601 start date/time, e.g., '2026-06-19T14:00:00+02:00'.")
        let startDate: String
        @Guide(description: "ISO8601 end date/time, e.g., '2026-06-19T15:00:00+02:00'.")
        let endDate: String
    }

    func call(arguments: Arguments) async throws -> String {
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Calendar event title cannot be empty." }
        
        let formatter = ISO8601DateFormatter()
        guard let start = formatter.date(from: arguments.startDate),
              let end = formatter.date(from: arguments.endDate) else {
            return "Failed to parse start or end date. Must be in ISO8601 format."
        }
        
        let success = await EventKitOrchestrator.createCalendarEvent(title: title, startDate: start, endDate: end)
        if success {
            return "Calendar event '\(title)' created from \(arguments.startDate) to \(arguments.endDate)."
        } else {
            return "Failed to create calendar event. Ensure permission is granted."
        }
    }
}

/// System control actions like locking the screen or emptying trash natively.
@available(macOS 26.0, *)
struct PowerStateTool: Tool {
    let name = "system_power_state"
    let description = "Trigger system power/state actions: lock screen or empty trash natively."

    @Generable
    struct Arguments {
        @Guide(description: "Action to perform: 'lock' or 'empty_trash'.")
        let action: String
    }

    func call(arguments: Arguments) async throws -> String {
        let act = arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch act {
        case "lock":
            NativeSystemOrchestrator.lockScreen()
            return "Locking screen."
        case "empty_trash":
            NativeSystemOrchestrator.emptyTrash()
            return "Emptying trash."
        default:
            return "Unsupported system action: \(arguments.action)."
        }
    }
}

/// Diagnose internet connection, reachability status, and Wi-Fi connection natively.
@available(macOS 26.0, *)
struct NetworkDiagnosticsTool: Tool {
    let name = "network_diagnostics"
    let description = "Run native reachability checks and check internet connectivity status."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let isReachable = await NetworkMonitor.shared.checkReachable()
        let wifiSSID = SystemDiagnostics.getWifiSSID()
        return "Internet Reachable: \(isReachable). Wi-Fi SSID: \(wifiSSID)."
    }
}

/// Read or write clipboard/pasteboard contents natively.
@available(macOS 26.0, *)
struct ClipboardTool: Tool {
    let name = "manage_clipboard"
    let description = "Read or write text contents to the macOS system clipboard natively."

    @Generable
    struct Arguments {
        @Guide(description: "One of 'read' or 'write'.")
        let action: String
        @Guide(description: "The text content to write (required only for 'write').")
        let content: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let action = arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "write" {
            guard let val = arguments.content else { return "Content is required for 'write' action." }
            NativeClipboard.set(val)
            return "Successfully copied text to clipboard."
        } else if action == "read" {
            let val = NativeClipboard.get()
            if val.isEmpty { return "Clipboard is currently empty." }
            return "Clipboard text: \(val)"
        } else {
            return "Invalid clipboard action. Must be 'read' or 'write'."
        }
    }
}

/// Native Spotlight file search.
@available(macOS 26.0, *)
struct SpotlightSearchTool: Tool {
    let name = "spotlight_search"
    let description = "Find files instantly on the Mac using the native Spotlight index (e.g. search for '.pdf' or specific project names)."

    @Generable
    struct Arguments {
        @Guide(description: "The search query, e.g. 'resume.pdf' or 'Sotto'.")
        let query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let q = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return "Query cannot be empty." }
        let results = SpotlightSearch.findFiles(matching: q)
        if results.isEmpty { return "No files found matching '\(q)'." }
        return "Spotlight results:\n" + results.joined(separator: "\n")
    }
}

/// Manage running applications and list visible window titles natively.
@available(macOS 26.0, *)
struct AppWindowManagerTool: Tool {
    let name = "manage_apps_windows"
    let description = "List running applications, active window titles, or bring a running app to the foreground using its PID."

    @Generable
    struct Arguments {
        @Guide(description: "Action to perform: 'list_apps', 'list_windows', or 'activate_app'.")
        let action: String
        @Guide(description: "The process ID (PID) of the app to bring to foreground (required only for 'activate_app').")
        let targetPID: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let action = arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "list_apps":
            let apps = WindowManager.getRunningApps()
            return "Running Applications:\n" + apps.joined(separator: "\n")
        case "list_windows":
            let windows = WindowManager.getWindowList()
            if windows.isEmpty { return "No visible windows found on screen." }
            return "Visible Windows:\n" + windows.joined(separator: "\n")
        case "activate_app":
            guard let pid = arguments.targetPID else { return "targetPID is required to activate an app." }
            let success = WindowManager.activateApp(pid: Int32(pid))
            return success ? "Successfully activated app with PID \(pid)." : "Failed to activate app with PID \(pid)."
        default:
            return "Unsupported action: \(arguments.action). Use 'list_apps', 'list_windows', or 'activate_app'."
        }
    }
}

/// Simulate key clicks and shortcuts natively.
@available(macOS 26.0, *)
struct KeySimulatorTool: Tool {
    let name = "simulate_keystroke"
    let description = "Simulate native keystrokes and keyboard shortcuts (e.g. Cmd+S, Cmd+W, tab, space, return, escape, arrow keys)."

    @Generable
    struct Arguments {
        @Guide(description: "The primary key, e.g. 's', 'w', 'return', 'tab', 'escape', 'left', 'right'.")
        let key: String
        @Guide(description: "If true, holds the Command (Cmd) key.")
        let cmd: Bool?
        @Guide(description: "If true, holds the Shift key.")
        let shift: Bool?
        @Guide(description: "If true, holds the Option (Alt) key.")
        let opt: Bool?
        @Guide(description: "If true, holds the Control (Ctrl) key.")
        let ctrl: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        let key = arguments.key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "Key cannot be empty." }
        
        let holdsCmd = arguments.cmd ?? false
        let holdsShift = arguments.shift ?? false
        let holdsOpt = arguments.opt ?? false
        let holdsCtrl = arguments.ctrl ?? false
        
        let success = await KeySimulator.simulate(
            key: key,
            cmd: holdsCmd,
            shift: holdsShift,
            opt: holdsOpt,
            ctrl: holdsCtrl
        )
        
        if success {
            var keysPressed: [String] = []
            if holdsCmd { keysPressed.append("Cmd") }
            if holdsShift { keysPressed.append("Shift") }
            if holdsOpt { keysPressed.append("Opt") }
            if holdsCtrl { keysPressed.append("Ctrl") }
            keysPressed.append(key)
            return "Simulated shortcut: \(keysPressed.joined(separator: "+"))."
        } else {
            return "Failed to simulate key '\(key)'."
        }
    }
}

/// Current weather + today's high/low for a city. Free, no API key (Open-Meteo).
@available(macOS 26.0, *)
struct WeatherTool: Tool {
    let name = "get_weather"
    let description = "Get the current weather and today's high/low temperature for a city. Use for any weather question."

    @Generable
    struct Arguments {
        @Guide(description: "The city name, e.g. 'Trier' or 'Berlin'. Leave empty to use the saved home city.")
        let city: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var city = (arguments.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if city.isEmpty { city = UserDefaults.standard.string(forKey: "sotto_home_city") ?? "" }
        guard !city.isEmpty else { return "Which city's weather do you want?" }
        return await WeatherService.summary(city: city) ?? "Couldn't get the weather for \(city) right now."
    }
}

/// The tools the Jarvis agent exposes to the on-device model.
///
/// Apple's guidance / tool-learning research: tool-selection accuracy plateaus around 8
/// tools and DROPS beyond that (redundant choices confuse the model). With 27 tools,
/// handing the small on-device model the whole catalog every call is the main reason
/// Jarvis felt like a toy. So `routed(for:)` scores intent groups by keyword and returns
/// only the most relevant ≤8 tools for each utterance; `all()` remains the safety net.
@available(macOS 26.0, *)
enum JarvisToolbox {
    static func all() -> [any Tool] {
        [
            SpotifyTool(), WeatherTool(), VolumeTool(), BrightnessTool(),
            OpenWebsiteTool(), OpenAppTool(), CreateNoteTool(), WebSearchTool(),
            ReadScreenTool(), ClickElementTool(), DraftSkillTool(), RunSkillTool(),
            RecallHistoryTool(), SystemStatusTool(), RAMMemoryStatusTool(),
            LocationGeocoderTool(), WikipediaLookupTool(), MemoryGoalTool(),
            AskClaudeTool(), ReminderTool(), CalendarTool(), PowerStateTool(),
            NetworkDiagnosticsTool(), ClipboardTool(), SpotlightSearchTool(),
            AppWindowManagerTool(), KeySimulatorTool(),
        ]
    }

    private struct Group {
        let keywords: [String]
        let make: () -> [any Tool]
    }

    private static let groups: [Group] = [
        Group(keywords: ["spotify", "music", "song", "play", "pause", "track", "artist", "skip", "tune", "album"],
              make: { [SpotifyTool()] }),
        Group(keywords: ["weather", "temperature", "forecast", "rain", "cold", "hot", "sunny", "snow", "wind"],
              make: { [WeatherTool()] }),
        Group(keywords: ["volume", "mute", "louder", "quieter", "sound", "brightness", "dim", "brighter"],
              make: { [VolumeTool(), BrightnessTool()] }),
        Group(keywords: ["battery", "wifi", "wi-fi", "disk", "ram", "memory", "status", "health", "internet", "network", "reachable", "connection"],
              make: { [SystemStatusTool(), RAMMemoryStatusTool(), NetworkDiagnosticsTool()] }),
        Group(keywords: ["open", "launch", "app", "website", "url", "browser", "window", "switch", "activate", "foreground"],
              make: { [OpenAppTool(), OpenWebsiteTool(), AppWindowManagerTool()] }),
        Group(keywords: ["search", "google", "look up", "wikipedia", "who is", "what is", "define", "research", "claude", "explain"],
              make: { [WebSearchTool(), WikipediaLookupTool(), AskClaudeTool()] }),
        Group(keywords: ["note", "remind", "reminder", "calendar", "event", "appointment", "meeting", "schedule", "clipboard", "copy", "paste"],
              make: { [CreateNoteTool(), ReminderTool(), CalendarTool(), ClipboardTool()] }),
        Group(keywords: ["file", "spotlight", "pdf", "document", "find file", "folder"],
              make: { [SpotlightSearchTool()] }),
        Group(keywords: ["lock", "trash", "empty", "sleep", "power"],
              make: { [PowerStateTool()] }),
        Group(keywords: ["read screen", "click", "button", "link", "on screen", "see", "page", "ocr"],
              make: { [ReadScreenTool(), ClickElementTool()] }),
        Group(keywords: ["location", "map", "where is", "geocode", "directions", "place", "address"],
              make: { [LocationGeocoderTool()] }),
        Group(keywords: ["keystroke", "press", "shortcut", "hotkey", "type"],
              make: { [KeySimulatorTool()] }),
        Group(keywords: ["skill", "learn", "routine", "goal", "remember", "recall", "history", "did you do", "have you"],
              make: { [DraftSkillTool(), RunSkillTool(), RecallHistoryTool(), MemoryGoalTool()] }),
    ]

    /// Common general-purpose tools used when an utterance matches no group's keywords.
    private static func defaultSet() -> [any Tool] {
        [OpenAppTool(), OpenWebsiteTool(), WebSearchTool(), WikipediaLookupTool(),
         SpotifyTool(), WeatherTool(), CreateNoteTool(), AskClaudeTool()]
    }

    /// Returns only the ≤8 most relevant tools for `command`, keeping the small model's
    /// choice sharp. Falls back to `defaultSet()` when nothing matches.
    static func routed(for command: String) -> [any Tool] {
        let lower = command.lowercased()
        let scored = groups
            .map { (score: $0.keywords.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }, group: $0) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        if scored.isEmpty { return defaultSet() }

        var picked: [any Tool] = []
        for entry in scored {
            for tool in entry.group.make() where picked.count < 8 && !picked.contains(where: { $0.name == tool.name }) {
                picked.append(tool)
            }
            if picked.count >= 8 { break }
        }
        return picked
    }
}
#endif
