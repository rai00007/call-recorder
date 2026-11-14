import Foundation
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    let settings = AppSettings()
    let store: RecordingStore
    let pipeline: ProcessingPipeline
    let manager: RecordingManager
    let meetings: MeetingStore
    let calendar = EventKitCalendarProvider()
    let notifier = NotificationPresenter()
    let prompts: PromptCoordinator
    @Published var selection: Set<UUID> = []
    @Published var searchText = ""
    @Published var showConsent = false
    private var pendingStart: (link: MeetingLink?, openLink: Bool)?
    var openMainWindow: () -> Void = {}
    var openRecordingWindow: (UUID) -> Void = { _ in }
    private var bag = Set<AnyCancellable>()

    init() {
        store = RecordingStore(root: settings.storageURL)
        pipeline = ProcessingPipeline(store: store, settings: settings)
        manager = RecordingManager(store: store, pipeline: pipeline, settings: settings)
        meetings = MeetingStore(recordingsRoot: settings.storageURL)
        prompts = PromptCoordinator(provider: calendar, ledger: PromptLedger())
        prompts.presenter = notifier
        notifier.coordinator = prompts
        prompts.isEnabled = { [weak self] in self?.settings.meetingPromptsEnabled ?? false }
        prompts.isRecording = { [weak self] in
            guard let s = self?.manager.state else { return false }
            return s == .starting || s == .recording
        }
        prompts.onRecord = { [weak self] event, openLink in self?.requestStart(meeting: event.link, openLink: openLink) }
        // Forward child changes so views only observe AppState.
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        meetings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        prompts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        notifier.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        calendar.changes.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.prompts.refresh() }.store(in: &bag)
        manager.$state.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.prompts.refresh() } }.store(in: &bag)
        settings.$meetingPromptsEnabled.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.prompts.refresh() } }.store(in: &bag)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settings.$storagePath.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.store.setRoot(self.settings.storageURL); self.meetings.setRoot(self.settings.storageURL); self.selection = [] }
        }.store(in: &bag)
    }

    static var legacyDir: URL { Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("recordings") }

    func startup() async {
        store.load()
        meetings.load()
        if !UserDefaults.standard.bool(forKey: "legacyImportDone") {
            await store.importLegacy(from: Self.legacyDir)
            UserDefaults.standard.set(true, forKey: "legacyImportDone")
        }
        await manager.recoverInterrupted()
        await notifier.refreshStatus()
        prompts.refresh()   // restores reminder scheduling after relaunch (the ledger prevents repeats)
    }

    /// Recording only ever starts from an explicit user action, after the consent reminder was acknowledged once.
    /// `meeting` links the new recording to a calendar meeting; `openLink` opens its join link (Join & Record).
    func requestStart(meeting: MeetingLink? = nil, openLink: Bool = false) {
        guard manager.state.canStart else { return }
        if let m = meeting { meetings.ensure(m) }
        if settings.consentAcknowledged { begin(meeting, openLink) }
        else { pendingStart = (meeting, openLink); showConsent = true; openMainWindow() }
    }
    func acknowledgeConsentAndStart() {
        settings.consentAcknowledged = true; showConsent = false
        let p = pendingStart; pendingStart = nil
        begin(p?.link, p?.openLink ?? false)
    }
    func cancelConsent() { pendingStart = nil }

    private func begin(_ meeting: MeetingLink?, _ openLink: Bool) {
        if openLink, let url = meeting?.snapshot.joinLink { NSWorkspace.shared.open(url) }
        Task {
            await manager.start(meeting: meeting)
            // For meeting recordings, select the new recording so Notes are one click away (no window is forced to the front).
            if meeting != nil, let id = manager.currentRecordingID { selection = [id] }
        }
    }

    /// Turns meeting prompts on/off. Returns a message to show when something needs the user's attention.
    func setMeetingPrompts(_ on: Bool) async -> String? {
        guard on else { settings.meetingPromptsEnabled = false; prompts.refresh(); return nil }
        let access = await calendar.requestAccess()
        guard access == .granted else {
            settings.meetingPromptsEnabled = false; prompts.refresh()
            switch access {
            case .writeOnly: return "Calendar access is write-only. Choose Full Access for Call Recorder in System Settings → Privacy & Security → Calendars."
            case .restricted: return "Calendar access is restricted on this Mac (for example by a profile)."
            default: return "Calendar access was not granted. Enable Call Recorder in System Settings → Privacy & Security → Calendars, then turn this on again."
            }
        }
        await notifier.requestAuthorization()
        settings.meetingPromptsEnabled = true; prompts.refresh()
        return notifier.canNotify ? nil : "Notifications are off, so meeting prompts will appear in a Call Recorder window instead. You can allow notifications in System Settings."
    }

    func requestStop() { Task { await manager.stop() } }

    func show(_ id: UUID) { selection = [id]; openMainWindow() }
}
