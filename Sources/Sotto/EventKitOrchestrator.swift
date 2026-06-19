import EventKit
import Foundation

struct EventKitOrchestrator {
    private static let eventStore = EKEventStore()
    
    static func requestAccess() async -> Bool {
        do {
            let eventAccess = try await eventStore.requestFullAccessToEvents()
            let reminderAccess = try await eventStore.requestFullAccessToReminders()
            return eventAccess && reminderAccess
        } catch {
            print("[EVENTKIT] Request access failed: \(error)")
            return false
        }
    }
    
    @discardableResult
    static func createReminder(title: String, dueDate: Date? = nil) async -> Bool {
        guard await requestAccess() else {
            print("[EVENTKIT] Access denied for reminders.")
            return false
        }
        
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        
        if let dueDate = dueDate {
            let calendar = Calendar.current
            reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }
        
        do {
            try eventStore.save(reminder, commit: true)
            print("[EVENTKIT] Native reminder saved successfully: \(title)")
            return true
        } catch {
            print("[EVENTKIT] Error saving reminder: \(error)")
            return false
        }
    }
    
    @discardableResult
    static func createCalendarEvent(title: String, startDate: Date, endDate: Date) async -> Bool {
        guard await requestAccess() else {
            print("[EVENTKIT] Access denied for events.")
            return false
        }
        
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = eventStore.defaultCalendarForNewEvents
        
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            print("[EVENTKIT] Native calendar event saved successfully: \(title)")
            return true
        } catch {
            print("[EVENTKIT] Error saving event: \(error)")
            return false
        }
    }
}
