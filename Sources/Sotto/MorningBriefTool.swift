import Foundation
import AppKit
import EventKit
import FoundationModels

// MARK: - MorningBriefTool
//
// Foundation Models Tool that assembles a spoken morning brief:
//   1. Today's calendar events (EventKit)
//   2. Today's incomplete reminders (EventKit)
//   3. Battery state (BatteryObserver)
//   4. Weather summary (WeatherService, city from UserDefaults "jarvis_home_city")
//   5. Recent tasks (TaskJournal)
// All data is fed to an on-device LanguageModelSession which composes a
// 2-sentence natural summary, then speaks it via AppController.
//
// Registration: add MorningBriefTool() to JarvisToolbox.all() in JarvisTools.swift.

struct MorningBriefTool: Tool {
    let name = "morning_brief"
    let description = "Deliver a spoken morning brief: today's calendar events, reminders, battery state, weather, and recent tasks. Takes no arguments."

    @Generable
    struct Arguments {}

    @Generable
    struct MorningBriefOutput {
        @Guide(description: "A natural 2-sentence spoken morning brief. Mention specific event titles, task names, and real numbers. No markdown, no bullet points.")
        let summary: String
    }

    // MARK: - call

    // EKEventStore isn't Sendable-audited by the SDK, but Apple documents it as
    // safe for concurrent read access; box it so `async let` can fan out to both
    // fetch functions below without tripping Swift 6 region isolation.
    private final class EventStoreBox: @unchecked Sendable {
        let store = EKEventStore()
    }

    func call(arguments: Arguments) async throws -> String {
        // One EKEventStore per invocation, boxed for the reason above.
        let storeBox = EventStoreBox()

        // ── 1. Gather all data concurrently ───────────────────────────────────
        async let calendarText  = fetchCalendarEvents(storeBox: storeBox)
        async let remindersText = fetchReminders(storeBox: storeBox)
        async let weatherText   = fetchWeather()

        let calendar  = await calendarText
        let reminders = await remindersText
        let weather   = await weatherText

        // Battery is synchronous/cheap — no need to parallelize
        let batteryText: String
        if let b = BatteryObserver.readBattery() {
            batteryText = "\(b.percent)% \(b.isCharging ? "(charging)" : "(on battery)")"
        } else {
            batteryText = "unknown"
        }

        let recentTasks = TaskJournal.recent(limit: 5)

        // ── 2. Compose data block ─────────────────────────────────────────────
        let data = """
            Calendar: \(calendar)
            Reminders: \(reminders)
            Battery: \(batteryText)
            Weather: \(weather)
            Recent tasks: \(recentTasks.isEmpty ? "none" : recentTasks)
            """

        // ── 3. On-device generation ───────────────────────────────────────────
        let summary: String

        if SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions:
                "You are JARVIS. Given this data, speak a 2-sentence morning brief. Be specific, mention actual events and tasks."
            )
            let prompt = "Data: \(data)"
            if let result = try? await session.respond(
                to: prompt,
                generating: MorningBriefOutput.self,
                options: GenerationOptions(temperature: 0.4)
            ) {
                summary = result.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Fallback: hand-craft from raw data
                summary = "Good morning. \(calendar.isEmpty ? "No events today." : "Today: \(calendar).")"
            }
        } else {
            // Model unavailable — compose a plain summary
            summary = "Good morning. \(calendar.isEmpty ? "No calendar events today." : "Today you have: \(calendar).")"
        }

        // ── 4. Speak + emit ───────────────────────────────────────────────────
        await MainActor.run {
            AppController.shared?.speak(summary)
        }
        await EventBus.shared.emit(.missionCompleted(id: "morning_brief", summary: summary))

        return summary
    }

    // MARK: - EventKit helpers

    private func fetchCalendarEvents(storeBox: EventStoreBox) async -> String {
        let store = storeBox.store
        guard (try? await store.requestFullAccessToEvents()) == true else {
            return "calendar access denied"
        }

        let now = Date()
        let endOfDay = Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 59, of: now
        ) ?? now.addingTimeInterval(86400)
        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)

        if events.isEmpty { return "no events today" }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        let lines = events.prefix(5).map { event -> String in
            let time  = formatter.string(from: event.startDate)
            let title = event.title ?? "Untitled"
            return "\(title) at \(time)"
        }
        return lines.joined(separator: "; ")
    }

    private func fetchReminders(storeBox: EventStoreBox) async -> String {
        let store = storeBox.store
        guard (try? await store.requestFullAccessToReminders()) == true else {
            return "reminders access denied"
        }

        return await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: nil)
            store.fetchReminders(matching: predicate) { fetched in
                guard let all = fetched else {
                    continuation.resume(returning: "none")
                    return
                }
                let pending = all.filter { !$0.isCompleted }
                if pending.isEmpty {
                    continuation.resume(returning: "no pending reminders")
                    return
                }
                let titles = pending.prefix(5)
                    .map { $0.title ?? "Untitled" }
                    .joined(separator: "; ")
                continuation.resume(returning: titles)
            }
        }
    }

    private func fetchWeather() async -> String {
        let city = UserDefaults.standard.string(forKey: "jarvis_home_city") ?? "your city"
        if let w = await WeatherService.summary(city: city) {
            return w
        }
        return "weather unavailable"
    }
}
