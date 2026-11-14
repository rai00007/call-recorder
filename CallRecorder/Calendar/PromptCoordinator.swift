import Foundation
import Combine

enum PromptAction { case joinAndRecord, recordOnly, dismiss }

@MainActor
protocol PromptPresenting: AnyObject {
    func present(_ events: [CalendarEvent])
    func update(_ events: [CalendarEvent])
    func dismiss()
}

/// Decides when to prompt. `refresh()` is idempotent and is called on launch, wake, calendar changes,
/// settings changes, recording state changes and from a timer. Recording never starts here; it only starts
/// after `choose` is called with a recording action.
@MainActor
final class PromptCoordinator: ObservableObject {
    @Published private(set) var access: CalendarAccess
    @Published private(set) var upcoming: [CalendarEvent] = []
    private(set) var visible: [CalendarEvent] = []

    var presenter: PromptPresenting?
    var isEnabled: () -> Bool = { true }
    var isRecording: () -> Bool = { false }
    var onRecord: (CalendarEvent, _ openLink: Bool) -> Void = { _, _ in }

    private let provider: CalendarProviding
    private let ledger: PromptLedger
    private let now: () -> Date
    private let schedule: (Date, @escaping @MainActor () -> Void) -> () -> Void
    private var cancelTimer: (() -> Void)?
    static let safetyInterval: TimeInterval = 300   // timers can fire late after sleep

    init(provider: CalendarProviding, ledger: PromptLedger, now: @escaping () -> Date = Date.init,
         schedule: @escaping (Date, @escaping @MainActor () -> Void) -> () -> Void = PromptCoordinator.timerSchedule) {
        self.provider = provider; self.ledger = ledger; self.now = now; self.schedule = schedule
        access = provider.access
    }

    nonisolated static func timerSchedule(_ date: Date, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let t = Timer(fire: date, interval: 0, repeats: false) { _ in Task { @MainActor in fire() } }
        RunLoop.main.add(t, forMode: .common)
        return { t.invalidate() }
    }

    func refresh() {
        cancelTimer?(); cancelTimer = nil
        let n = now()
        access = provider.access
        guard isEnabled(), access == .granted else { upcoming = []; clearVisible(); return }
        ledger.prune(now: n)
        let eligible = provider.events(from: n.addingTimeInterval(-300), to: n.addingTimeInterval(24 * 3600)).filter { $0.snapshot.joinLink != nil }
        upcoming = eligible.filter { $0.snapshot.end > n }

        // Keep the visible prompt in sync: drop deleted/started meetings, pick up edits.
        let fresh = Dictionary(eligible.map { ($0.occurrenceKey, $0) }, uniquingKeysWith: { a, _ in a })
        let still = visible.compactMap { fresh[$0.occurrenceKey] }.filter { $0.snapshot.start > n }
        if isRecording() { clearVisible() }
        else if still.isEmpty { clearVisible() }
        else if still != visible { visible = still; presenter?.update(still) }

        if !isRecording() {
            let shown = Set(visible.map(\.occurrenceKey))
            let due = ReminderPlanner.due(eligible, now: n, prompted: { ledger.contains($0) || shown.contains($0) })
            if !due.isEmpty {
                ledger.record(due)   // recorded when shown, so a refresh or relaunch never repeats it
                if visible.isEmpty { visible = due; presenter?.present(due) }
                else { visible = (visible + due).sorted { $0.snapshot.start < $1.snapshot.start }; presenter?.update(visible) }
            }
        }

        var next = n.addingTimeInterval(Self.safetyInterval)
        if let r = ReminderPlanner.nextFire(eligible, now: n, prompted: { ledger.contains($0) }) { next = min(next, r) }
        if let s = visible.map(\.snapshot.start).min() { next = min(next, s) }
        cancelTimer = schedule(max(next, n.addingTimeInterval(1))) { [weak self] in self?.refresh() }
    }

    func choose(_ action: PromptAction, event: CalendarEvent?) {
        let group = visible
        visible = []
        ledger.record(group)
        presenter?.dismiss()
        if action != .dismiss, let e = event { onRecord(e, action == .joinAndRecord) }
    }

    private func clearVisible() {
        guard !visible.isEmpty else { return }
        visible = []; presenter?.dismiss()
    }
}
