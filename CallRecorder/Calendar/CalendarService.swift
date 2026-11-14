import Foundation
import Combine
import EventKit

enum CalendarAccess: Equatable { case notDetermined, granted, denied, restricted, writeOnly }

protocol CalendarProviding: AnyObject {
    var access: CalendarAccess { get }
    func requestAccess() async -> CalendarAccess
    /// Eligible events only: cancelled, declined and all-day events are already filtered out.
    func events(from: Date, to: Date) -> [CalendarEvent]
    var changes: AnyPublisher<Void, Never> { get }
}

/// Read-only EventKit access. Nothing here ever saves or removes an event.
final class EventKitCalendarProvider: CalendarProviding {
    private let store = EKEventStore()

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }

    func requestAccess() async -> CalendarAccess {
        _ = try? await store.requestFullAccessToEvents()
        return access
    }

    var changes: AnyPublisher<Void, Never> {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store).map { _ in () }.eraseToAnyPublisher()
    }

    func events(from: Date, to: Date) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred).compactMap(Self.map).sorted { $0.snapshot.start < $1.snapshot.start }
    }

    private static func map(_ e: EKEvent) -> CalendarEvent? {
        guard e.status != .canceled, !e.isAllDay, let start = e.startDate, let end = e.endDate else { return nil }
        let attendees = e.attendees ?? []
        if attendees.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) { return nil }
        let invitees = attendees.map { p -> Invitee in
            let mail = p.url.scheme == "mailto" ? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") : nil
            return Invitee(name: p.name ?? mail ?? "Unknown", email: mail)
        }
        let ext = e.calendarItemExternalIdentifier ?? e.calendarItemIdentifier
        let snap = MeetingSnapshot(title: (e.title ?? "").isEmpty ? "Meeting" : e.title, start: start, end: end,
                                   calendarName: e.calendar?.title, invitees: invitees,
                                   joinLink: MeetingLinkExtractor.joinLink(url: e.url, location: e.location, notes: e.notes))
        let ref = EventRef(calendarItemID: e.calendarItemIdentifier, externalID: ext, occurrenceDate: e.occurrenceDate ?? start, calendarID: e.calendar?.calendarIdentifier ?? "")
        return CalendarEvent(ref: ref, snapshot: snap)
    }
}
