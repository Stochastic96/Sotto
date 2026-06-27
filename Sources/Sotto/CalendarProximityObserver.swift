import EventKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - CalendarProximityObserver
//
// Checks EventKit every 2 minutes for events starting within 10 minutes.
// Uses Apple Intelligence to generate a smart briefing — attendees, agenda, prep notes —
// so Jarvis can tell you exactly what's coming, not just the event name.
//
// All data stays on-device. EventKit is local. Foundation Models runs locally.
// Zero data leaves the Mac.
//
// Example:
//   "Design Review in 8 minutes with Sarah and Mike.
//    Your last note about this project: 'finalize color palette'.
//    Shall I open the Figma link from yesterday?"

enum CalendarProximityObserver {

    private static let store = EKEventStore()
    private static var warnedEventIDs = Set<String>()

    static func start() {
        Task.detached(priority: .background) { await requestAndWatch() }
    }

    // MARK: - Main loop

    private static func requestAndWatch() async {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            print("[CALENDAR] Access denied — proximity alerts disabled.")
            return
        }
        print("[CALENDAR] Access granted — watching for upcoming events.")

        while true {
            await checkUpcomingEvents()
            try? await Task.sleep(for: .seconds(120)) // every 2 min
        }
    }

    private static func checkUpcomingEvents() async {
        let now = Date()
        let horizon = now.addingTimeInterval(11 * 60) // look 11 min ahead
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let events = store.events(matching: predicate)

        for event in events {
            let id = event.eventIdentifier ?? event.title ?? "\(event.startDate.timeIntervalSince1970)"
            guard !warnedEventIDs.contains(id) else { continue }
            warnedEventIDs.insert(id)

            let minutesAway = max(0, Int(event.startDate.timeIntervalSince(now) / 60))
            let attendeeNames = event.attendees?
                .compactMap { $0.name }
                .filter { $0 != EKParticipant.self.description() }
                ?? []

            await EventBus.shared.emit(.calendarEventSoon(
                title: event.title ?? "Meeting",
                minutesAway: minutesAway,
                attendees: attendeeNames
            ))

            // Use Apple Intelligence to generate a rich briefing if time permits (> 3 min away)
            if minutesAway > 3 {
                if let briefing = await generateBriefing(for: event, minutesAway: minutesAway) {
                    await EventBus.shared.emit(.suggestionReady(message: briefing, command: nil))
                }
            }
        }
    }

    // MARK: - Apple Intelligence briefing (on-device, private)

    private static func generateBriefing(for event: EKEvent, minutesAway: Int) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let attendees = event.attendees?.compactMap { $0.name }.prefix(4).joined(separator: ", ") ?? "no attendees"
            let notes = event.notes ?? ""
            let location = event.location ?? ""

            let session = LanguageModelSession(instructions: """
                You are preparing a 1-sentence briefing for an upcoming calendar event.
                Be specific, actionable, and brief. Mention who's attending if relevant.
                Never say "I" — address the user directly or be neutral.
                """)

            let prompt = """
                Event: \(event.title ?? "Meeting")
                Starts in: \(minutesAway) minutes
                Attendees: \(attendees)
                Location: \(location.isEmpty ? "not specified" : location)
                Notes: \(notes.isEmpty ? "none" : String(notes.prefix(200)))
                """

            guard let result = try? await session.respond(
                to: prompt,
                generating: EventBriefing.self,
                options: GenerationOptions(temperature: 0.3)
            ) else { return nil }

            let briefing = result.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return briefing.isEmpty ? nil : briefing
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct EventBriefing {
        @Guide(description: "One sentence briefing about the upcoming event. E.g. 'Design review with Sarah in 7 minutes — open Figma?'")
        let text: String
    }
    #endif
}
