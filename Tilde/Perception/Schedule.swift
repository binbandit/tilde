import EventKit
import Foundation

/// Your day, read from Calendar and Reminders. Read-only: tilde never adds,
/// moves or answers anything here.
@MainActor
final class Schedule {
    private let store = EKEventStore()

    enum Access { case granted, denied, notAsked }

    var calendarAccess: Access { Self.access(EKEventStore.authorizationStatus(for: .event)) }
    var remindersAccess: Access { Self.access(EKEventStore.authorizationStatus(for: .reminder)) }

    func requestAccess() async {
        if calendarAccess == .notAsked { _ = try? await store.requestFullAccessToEvents() }
        if remindersAccess == .notAsked { _ = try? await store.requestFullAccessToReminders() }
    }

    /// Events from now until `hours` ahead, one line each, with who and what's in the notes.
    func upcoming(hours: Double = 12) -> String {
        guard calendarAccess == .granted else { return "" }
        let now = Date.now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map(Self.describe)
            .joined(separator: "\n")
    }

    /// Reminders due by the end of `days` days, overdue first.
    func remindersDue(days: Double = 1) async -> String {
        guard remindersAccess == .granted else { return "" }
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(days * 86_400)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        let reminders: [(title: String, due: Date?)] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: (found ?? []).map { ($0.title ?? "", $0.dueDateComponents?.date) })
            }
        }
        return reminders
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(10)
            .map { "- \($0.title)" + ($0.due.map { " (due \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? "") }
            .joined(separator: "\n")
    }

    private static func describe(_ event: EKEvent) -> String {
        let time = "\(event.startDate.formatted(date: .omitted, time: .shortened))-\(event.endDate.formatted(date: .omitted, time: .shortened))"
        var line = "- \(time) \(event.title ?? "Busy")"
        let people = (event.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        if !people.isEmpty { line += " with \(people.prefix(5).joined(separator: ", "))" }
        if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            line += ". Notes: " + notes.split(separator: "\n").prefix(3).joined(separator: " ").prefix(200)
        }
        return line
    }

    private static func access(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }
}
