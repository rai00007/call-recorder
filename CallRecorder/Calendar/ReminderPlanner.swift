import Foundation

enum ReminderPlanner {
    static let lead: TimeInterval = 120

    /// Occurrences whose reminder time has passed but that have not started. Meetings already underway are never due.
    static func due(_ events: [CalendarEvent], now: Date, prompted: (String) -> Bool, lead: TimeInterval = lead) -> [CalendarEvent] {
        events.filter { $0.snapshot.joinLink != nil && !prompted($0.occurrenceKey) && $0.snapshot.start.addingTimeInterval(-lead) <= now && now < $0.snapshot.start }
            .sorted { $0.snapshot.start < $1.snapshot.start }
    }

    /// Earliest future reminder time among not-yet-prompted occurrences.
    static func nextFire(_ events: [CalendarEvent], now: Date, prompted: (String) -> Bool, lead: TimeInterval = lead) -> Date? {
        events.filter { $0.snapshot.joinLink != nil && !prompted($0.occurrenceKey) }
            .map { $0.snapshot.start.addingTimeInterval(-lead) }.filter { $0 > now }.min()
    }
}

/// Persists which occurrences were already prompted, so a prompt appears once even across relaunches.
final class PromptLedger {
    private let d: UserDefaults
    private let key = "promptedOccurrences"
    private var entries: [String: Double]

    init(defaults: UserDefaults = .standard) {
        d = defaults
        entries = defaults.dictionary(forKey: "promptedOccurrences") as? [String: Double] ?? [:]
    }
    func contains(_ k: String) -> Bool { entries[k] != nil }
    func record(_ events: [CalendarEvent]) {
        for e in events { entries[e.occurrenceKey] = e.snapshot.start.timeIntervalSince1970 }
        d.set(entries, forKey: key)
    }
    func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-7 * 86400).timeIntervalSince1970
        let kept = entries.filter { $0.value >= cutoff }
        if kept.count != entries.count { entries = kept; d.set(kept, forKey: key) }
    }
}
