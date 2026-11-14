import Foundation
import CryptoKit

/// A calendar attendee as listed on the event. These are invitees, never verified call participants.
struct Invitee: Codable, Equatable {
    var name: String
    var email: String?
}

/// Pointer back to the calendar event. Informational only: it may stop resolving if the event is edited or deleted.
struct EventRef: Codable, Equatable {
    var calendarItemID: String
    var externalID: String
    var occurrenceDate: Date
    var calendarID: String
}

/// Frozen copy of the event details taken when a meeting is first linked. Never updated afterwards.
struct MeetingSnapshot: Codable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var calendarName: String?
    var invitees: [Invitee] = []
    var joinLink: URL?
}

/// Stored inside a recording's metadata.json so the recording folder is self-contained.
struct MeetingLink: Codable, Equatable {
    var meetingId: UUID
    var occurrenceKey: String
    var ref: EventRef?
    var snapshot: MeetingSnapshot
}

/// One occurrence of a calendar event (a recurring meeting yields one `CalendarEvent` per occurrence).
struct CalendarEvent: Identifiable, Equatable {
    var ref: EventRef
    var snapshot: MeetingSnapshot

    init(ref: EventRef, snapshot: MeetingSnapshot) { self.ref = ref; self.snapshot = snapshot }
    init(externalID: String, occurrenceDate: Date? = nil, calendarID: String = "cal", snapshot: MeetingSnapshot) {
        self.init(ref: EventRef(calendarItemID: externalID, externalID: externalID, occurrenceDate: occurrenceDate ?? snapshot.start, calendarID: calendarID),
                  snapshot: snapshot)
    }

    var occurrenceKey: String { Self.key(externalID: ref.externalID, occurrenceDate: ref.occurrenceDate) }
    /// Stable per occurrence, so the same meeting always maps to the same folder and sidebar row.
    var id: UUID { Self.meetingID(forKey: occurrenceKey) }
    var link: MeetingLink { MeetingLink(meetingId: id, occurrenceKey: occurrenceKey, ref: ref, snapshot: snapshot) }

    static func key(externalID: String, occurrenceDate: Date) -> String { "\(externalID)|\(Int(occurrenceDate.timeIntervalSince1970))" }

    static func meetingID(forKey key: String) -> UUID {
        let d = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }
}
