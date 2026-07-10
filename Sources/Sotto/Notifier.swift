import Foundation
import UserNotifications

// MARK: - Notifier
//
// Native macOS notifications (top-right, collected in Notification Center) for
// every NON-live outcome: Jarvis replies, weather answers, finished long tasks,
// scheduled reminders, and system events. The on-screen HUD is reserved for the
// live voice indicator only (listening / thinking / a clarifying question), so
// results never sit in a big box on top of the user's work.
//
// This is deliberately text-first and minimal — one title line, an optional
// body line, no custom chrome. It requires a one-time authorization prompt and
// a real app bundle; when Sotto is run as a bare binary (no bundle id) the
// notification layer is unavailable and posts are dropped rather than crashing.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// UNUserNotificationCenter needs a bundle identifier; a bare `swift run`
    /// binary has none and would trap on `.current()`.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Request authorization and register as delegate so banners appear even
    /// though Sotto is a background/menu-bar agent. Call once at launch.
    func start() {
        guard available else {
            print("[NOTIFIER] No bundle identifier (bare binary) — native notifications disabled.")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { print("[NOTIFIER] Authorization error: \(error.localizedDescription)") }
            else { print("[NOTIFIER] Notifications authorized: \(granted)") }
        }
    }

    /// Post an immediate notification. A title-only message promotes its single
    /// line to the title so the banner reads cleanly.
    func post(title: String, body: String = "", sound: Bool = false) {
        guard available else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !b.isEmpty else { return }

        let content = UNMutableNotificationContent()
        if t.isEmpty {
            content.title = b
        } else {
            content.title = t
            content.body = b
        }
        if sound { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil          // nil = deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners while Sotto is the active (background) process.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
