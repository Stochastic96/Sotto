import AppKit
import Foundation

// MARK: - EventHandler
//
// The single subscriber that turns EventBus events into user-visible actions.
// Runs as a perpetual background Task. Dispatches UI work back to MainActor.
//
// Architecture:
//   Observer (produces event) → EventBus.emit → EventHandler.handle → AppController (HUD + voice)
//
// The handler is intentionally "dumb" — it reacts to what observers publish.
// It does NOT generate suggestions; it only surfaces them.

enum EventHandler {

    static func start() {
        Task.detached(priority: .userInitiated) {
            print("[EVENTHANDLER] Started — listening on EventBus.")
            for await event in await EventBus.shared.makeStream() {
                await handle(event)
            }
        }
    }

    // MARK: - Dispatch

    private static func handle(_ event: EventBus.Event) async {
        switch event {

        // ─── Battery ───────────────────────────────────────────────────────────
        case .batteryLow(let percent):
            let isCritical = percent <= 5
            let hud  = isCritical ? "⚡ \(percent)% — plug in NOW" : "🔋 \(percent)% — connect charger soon"
            let voice = isCritical ? "Critical battery, plug in now" : "Battery at \(percent) percent, connect charger"
            await show(hud: hud, speak: voice)

        case .batteryCharging:
            // Silent — don't interrupt when the user plugs in
            break

        // ─── Downloads ─────────────────────────────────────────────────────────
        case .fileArrived(let url, let ext):
            if let (hud, cmd) = fileSuggestion(name: url.lastPathComponent, ext: ext) {
                await show(hud: hud)
                if let command = cmd {
                    // Route the suggestion through the existing Jarvis pipeline
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("SottoSuggestion"),
                            object: nil,
                            userInfo: ["text": hud, "command": command]
                        )
                    }
                }
            }

        // ─── Clipboard ─────────────────────────────────────────────────────────
        case .clipboardChanged(let content, let kind):
            print("[EVENT] Clipboard changed: \(kind) (\(content.count) chars)")
            // No HUD on every clipboard change — only on .suggestionReady

        // ─── Suggestions (from any observer) ───────────────────────────────────
        case .suggestionReady(let message, _):
            // Show briefly — user can say "yes" or "do it" to act
            await show(hud: "💡 \(message)", duration: 4.0)

        // ─── Calendar ──────────────────────────────────────────────────────────
        case .calendarEventSoon(let title, let minutesAway, let attendees):
            let who = attendees.isEmpty ? "" : " with \(attendees.prefix(2).joined(separator: " & "))"
            let hud: String
            let voice: String
            if minutesAway <= 1 {
                hud   = "📅 \(title)\(who) — starting now"
                voice = "\(title) is starting now"
            } else {
                hud   = "📅 \(title)\(who) in \(minutesAway) min"
                voice = "\(title) in \(minutesAway) minutes"
            }
            await show(hud: hud, speak: voice)

        // ─── Missions ──────────────────────────────────────────────────────────
        case .missionCompleted(_, let summary):
            await show(hud: "✓ \(summary)", speak: summary)

        case .missionFailed(_, let reason):
            await show(hud: "⚠️ \(reason)", speak: "Task failed: \(reason)")

        case .missionStarted(_, let goal):
            print("[EVENT] Mission started: \(goal)")

        // ─── Skills ────────────────────────────────────────────────────────────
        case .skillEnabled(let name, let trigger):
            await show(hud: "✅ Skill '\(name)' active — say \"\(trigger)\"")
            print("[EVENT] Skill enabled: \(name), trigger: \(trigger)")

        case .skillDrafted(let name, let description):
            await show(hud: "📝 New skill drafted: \(name)")
            print("[EVENT] Skill drafted: \(name) — \(description)")

        // ─── Network ───────────────────────────────────────────────────────────
        case .networkChanged(let isOnline):
            if !isOnline { await show(hud: "⚠️ Offline — cloud features paused") }
            print("[EVENT] Network: \(isOnline ? "online" : "offline")")

        // ─── App Launched ──────────────────────────────────────────────────────
        case .appLaunched(let name, _):
            print("[EVENT] App launched: \(name)")

        // ─── User spoke (pass-through, already handled by AppController) ───────
        case .userSpoke:
            break

        // ─── Conversation turns (consumed by ConversationMemory, not the HUD) ──
        case .conversationTurn:
            break

        // ─── New trigger/engine/output events (handled by SottoTrigger/Engine/Output) ──
        default:
            break
        }
    }

    // MARK: - UI helpers

    @MainActor
    private static func show(hud: String, speak text: String? = nil, duration: Double = 2.5) {
        AppController.shared?.showHUD(hud)
        if let t = text { AppController.shared?.speak(t) }
        if duration > 0 {
            Task {
                try? await Task.sleep(for: .seconds(duration))
                AppController.shared?.hideHUD()
            }
        }
    }

    // MARK: - File suggestion table (deterministic, 0 tokens)

    private static func fileSuggestion(name: String, ext: String) -> (hud: String, command: String?)? {
        switch ext {
        case "zip", "tar", "gz", "bz2", "7z", "rar":
            return ("📦 \(name) — unzip it?", "unzip ~/Downloads/\(name)")
        case "dmg":
            return ("💿 \(name) — install it?", nil)
        case "pdf":
            return ("📄 \(name) — summarize it?", "summarize pdf ~/Downloads/\(name)")
        case "swift":
            return ("🦅 \(name) — review this Swift file?", nil)
        case "py":
            return ("🐍 \(name) — review this Python file?", nil)
        case "sh", "bash", "zsh":
            return ("📜 \(name) — review before running?", nil)
        case "ipa", "app":
            return ("📲 \(name) downloaded", nil)
        default:
            return nil
        }
    }
}
