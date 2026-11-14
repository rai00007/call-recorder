import XCTest
import Combine
@testable import CallRecorderCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func makeEvent(_ key: String, start: TimeInterval, length: TimeInterval = 1800, title: String = "Standup", occurrence: Date? = nil, link: String? = "https://meet.google.com/abc-defg-hij") -> CalendarEvent {
    CalendarEvent(externalID: key, occurrenceDate: occurrence, snapshot: MeetingSnapshot(
        title: title, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(start + length), calendarName: "Work",
        invitees: [Invitee(name: "Ana", email: "ana@x.com")], joinLink: link.flatMap(URL.init(string:))))
}

final class FakeProvider: CalendarProviding {
    var access: CalendarAccess = .granted
    var events: [CalendarEvent] = []
    let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    func requestAccess() async -> CalendarAccess { access }
    func events(from: Date, to: Date) -> [CalendarEvent] { events.filter { $0.snapshot.end > from && $0.snapshot.start < to } }
}

@MainActor
final class FakePresenter: PromptPresenting {
    var presented: [[CalendarEvent]] = [], updated: [[CalendarEvent]] = [], dismissed = 0
    func present(_ e: [CalendarEvent]) { presented.append(e) }
    func update(_ e: [CalendarEvent]) { updated.append(e) }
    func dismiss() { dismissed += 1 }
}

final class ReminderPlannerTests: XCTestCase {
    func due(_ evs: [CalendarEvent], at offset: TimeInterval, prompted: Set<String> = []) -> [CalendarEvent] {
        ReminderPlanner.due(evs, now: t0.addingTimeInterval(offset), prompted: { prompted.contains($0) })
    }
    func testWindowBoundaries() {
        let e = makeEvent("a", start: 600)
        XCTAssertTrue(due([e], at: 600 - 121).isEmpty)
        XCTAssertEqual(due([e], at: 600 - 120).count, 1)
        XCTAssertEqual(due([e], at: 599).count, 1)
        XCTAssertTrue(due([e], at: 600).isEmpty)       // already underway: stale
        XCTAssertTrue(due([e], at: 900).isEmpty)
    }
    func testLedgerAndNoLink() {
        let e = makeEvent("a", start: 600)
        XCTAssertTrue(due([e], at: 500, prompted: [e.occurrenceKey]).isEmpty)
        XCTAssertTrue(due([makeEvent("b", start: 600, link: nil)], at: 500).isEmpty)
    }
    func testRecurringOccurrencesAreSeparate() {
        let a = makeEvent("series", start: 600, occurrence: t0.addingTimeInterval(600))
        let b = makeEvent("series", start: 600 + 86400, occurrence: t0.addingTimeInterval(600 + 86400))
        XCTAssertNotEqual(a.occurrenceKey, b.occurrenceKey)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(due([a, b], at: 500, prompted: [b.occurrenceKey]).map(\.occurrenceKey), [a.occurrenceKey])
    }
    func testOverlapSortedAndNextFire() {
        let a = makeEvent("a", start: 700), b = makeEvent("b", start: 650)
        XCTAssertEqual(due([a, b], at: 600).map(\.ref.externalID), ["b", "a"])
        XCTAssertEqual(ReminderPlanner.nextFire([a, b], now: t0, prompted: { _ in false }), t0.addingTimeInterval(530))
        XCTAssertNil(ReminderPlanner.nextFire([a], now: t0.addingTimeInterval(600), prompted: { _ in false }))
    }
}

@MainActor
final class PromptCoordinatorTests: XCTestCase {
    var now = t0
    let provider = FakeProvider(), presenter = FakePresenter()
    var recording = false, enabled = true
    var recorded: [(String, Bool)] = []
    var scheduled: [Date] = []
    var defaults = UserDefaults(suiteName: "crtests-" + UUID().uuidString)!

    func make(_ ledgerDefaults: UserDefaults? = nil) -> PromptCoordinator {
        let c = PromptCoordinator(provider: provider, ledger: PromptLedger(defaults: ledgerDefaults ?? defaults), now: { self.now },
                                  schedule: { d, _ in self.scheduled.append(d); return {} })
        c.presenter = presenter
        c.isEnabled = { self.enabled }; c.isRecording = { self.recording }
        c.onRecord = { e, open in self.recorded.append((e.snapshot.title, open)) }
        return c
    }
    func at(_ s: TimeInterval) { now = t0.addingTimeInterval(s) }

    func testPromptsOnceAndNotAgainAfterRefreshOrRestart() {
        let e = makeEvent("a", start: 600); provider.events = [e]
        let c = make(); at(300); c.refresh()
        XCTAssertTrue(presenter.presented.isEmpty)
        at(480); c.refresh()
        XCTAssertEqual(presenter.presented.count, 1)
        provider.subject.send(); at(500); c.refresh(); c.refresh()           // calendar refreshes
        XCTAssertEqual(presenter.presented.count, 1)
        c.choose(.dismiss, event: nil)
        at(520); c.refresh()
        XCTAssertEqual(presenter.presented.count, 1)
        let c2 = make(); c2.refresh()                                         // "restart": new coordinator, same ledger
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testLaunchOrWakeInsideWindowPromptsButNotAfterStart() {
        provider.events = [makeEvent("a", start: 600)]
        at(560); make().refresh()
        XCTAssertEqual(presenter.presented.count, 1)
        let other = FakePresenter(); defaults = UserDefaults(suiteName: "crtests-" + UUID().uuidString)!
        let c = make(); c.presenter = other; at(700); c.refresh()
        XCTAssertTrue(other.presented.isEmpty)                                // meeting underway: no stale prompt
    }

    func testSuppressedWhileRecordingThenShownIfStoppedBeforeStart() {
        provider.events = [makeEvent("a", start: 600)]
        let c = make(); recording = true; at(500); c.refresh()
        XCTAssertTrue(presenter.presented.isEmpty)
        recording = false; at(560); c.refresh()
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testRecordingStartingDismissesVisiblePrompt() {
        provider.events = [makeEvent("a", start: 600)]
        let c = make(); at(500); c.refresh()
        recording = true; c.refresh()
        XCTAssertEqual(presenter.dismissed, 1); XCTAssertTrue(c.visible.isEmpty)
    }

    func testOverlappingMeetingsOnePromptAndMerge() {
        provider.events = [makeEvent("a", start: 600, title: "A"), makeEvent("b", start: 620, title: "B")]
        let c = make(); at(500); c.refresh()
        XCTAssertEqual(presenter.presented.count, 1); XCTAssertEqual(presenter.presented[0].map(\.snapshot.title), ["A", "B"])
        provider.events.append(makeEvent("c", start: 630, title: "C")); at(515); c.refresh()
        XCTAssertEqual(presenter.presented.count, 1); XCTAssertEqual(presenter.updated.last?.count, 3)
    }

    func testActionsRecordOnlyWhenChosen() {
        let e = makeEvent("a", start: 600, title: "Sync"); provider.events = [e]
        let c = make(); at(500); c.refresh()
        XCTAssertTrue(recorded.isEmpty)                                       // nothing records before a choice
        c.choose(.dismiss, event: nil); XCTAssertTrue(recorded.isEmpty)
        defaults = UserDefaults(suiteName: "crtests-" + UUID().uuidString)!
        let c2 = make(); c2.refresh(); c2.choose(.joinAndRecord, event: e)
        XCTAssertEqual(recorded.map(\.0), ["Sync"]); XCTAssertEqual(recorded.map(\.1), [true])
        defaults = UserDefaults(suiteName: "crtests-" + UUID().uuidString)!
        let c3 = make(); c3.refresh(); c3.choose(.recordOnly, event: e)
        XCTAssertEqual(recorded.last?.1, false)
    }

    func testDisabledOrDeniedShowsNothing() {
        provider.events = [makeEvent("a", start: 600)]
        let c = make(); at(500)
        enabled = false; c.refresh(); XCTAssertTrue(presenter.presented.isEmpty)
        enabled = true; provider.access = .denied; c.refresh(); XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(c.access, .denied); XCTAssertTrue(c.upcoming.isEmpty)
    }

    func testDeletedOrEditedEvents() {
        let e = makeEvent("a", start: 600); provider.events = [e]
        let c = make(); at(400); c.refresh()
        provider.events = []; c.refresh(); at(500); c.refresh()               // deleted before reminder
        XCTAssertTrue(presenter.presented.isEmpty)
        provider.events = [makeEvent("a", start: 1200, occurrence: e.ref.occurrenceDate)]   // moved later, same occurrence
        c.refresh(); XCTAssertTrue(presenter.presented.isEmpty)
        at(1100); c.refresh(); XCTAssertEqual(presenter.presented.count, 1)
        provider.events = []; c.refresh()                                      // deleted while prompt visible
        XCTAssertEqual(presenter.dismissed, 1)
    }

    func testSchedulesNextReminder() {
        provider.events = [makeEvent("a", start: 600)]
        let c = make(); at(200); c.refresh()
        XCTAssertEqual(scheduled.last, t0.addingTimeInterval(480))
    }
}
