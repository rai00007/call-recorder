import Foundation

/// A calendar meeting the user interacted with (recorded it or took notes). The snapshot is written once and never updated,
/// so later calendar edits or deletion cannot change what was saved.
struct Meeting: Codable, Identifiable, Equatable {
    var id: UUID
    var occurrenceKey: String
    var ref: EventRef?
    var snapshot: MeetingSnapshot
    var createdAt: Date
}

/// <root>/Meetings/<id>/{meeting.json, notes.md}. Lives next to the recording folders, which ignore it (no metadata.json).
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    private(set) var root: URL
    private let fm = FileManager.default

    init(recordingsRoot: URL) { root = recordingsRoot }

    static func folder(root: URL, _ id: UUID) -> URL { root.appendingPathComponent("Meetings").appendingPathComponent(id.uuidString) }
    func folder(_ id: UUID) -> URL { Self.folder(root: root, id) }
    func notesURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(RecFile.notes.rawValue) }
    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func setRoot(_ url: URL) { root = url; load() }

    func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let dirs = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("Meetings"), includingPropertiesForKeys: nil)) ?? []
        meetings = dirs.compactMap { try? dec.decode(Meeting.self, from: Data(contentsOf: $0.appendingPathComponent("meeting.json"))) }
            .sorted { $0.snapshot.start > $1.snapshot.start }
    }

    /// Returns the saved meeting, creating it from the event on first use. An existing snapshot is never overwritten.
    @discardableResult
    func ensure(_ event: CalendarEvent) -> Meeting {
        if let m = meeting(event.id) { return m }
        return ensure(event.link)
    }

    @discardableResult
    func ensure(_ link: MeetingLink) -> Meeting {
        if let m = meeting(link.meetingId) { return m }
        let m = Meeting(id: link.meetingId, occurrenceKey: link.occurrenceKey, ref: link.ref, snapshot: link.snapshot, createdAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try fm.createDirectory(at: folder(m.id), withIntermediateDirectories: true)
            try enc.encode(m).write(to: folder(m.id).appendingPathComponent("meeting.json"), options: .atomic)
        } catch { FileHandle.standardError.write(Data("meeting save failed: \(error)\n".utf8)) }
        meetings.append(m)
        meetings.sort { $0.snapshot.start > $1.snapshot.start }
        return m
    }
}
