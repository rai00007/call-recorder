import AppKit
import UserNotifications

/// Shows the prompt as a macOS notification when the app is in the background, otherwise as an in-app panel.
/// If notification permission is not granted the panel is used instead, so the prompt is never lost.
/// Clicking the notification opens the panel, where the meeting selector and the three actions live.
@MainActor
final class NotificationPresenter: NSObject, ObservableObject, PromptPresenting, UNUserNotificationCenterDelegate {
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    let panel = MeetingPromptPanel()
    var coordinator: PromptCoordinator?
    private let notificationID = "meeting-prompt"
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    var canNotify: Bool { status == .authorized || status == .provisional }
    var statusText: String {
        switch status {
        case .authorized, .provisional: "Allowed"
        case .denied: "Denied — prompts appear in a Call Recorder window instead"
        default: "Not asked yet"
        }
    }

    override init() {
        super.init()
        center.delegate = self
        panel.model.choose = { [weak self] action, event in self?.coordinator?.choose(action, event: event) }
        panel.onUserClosed = { [weak self] in
            if self?.coordinator?.visible.isEmpty == false { self?.coordinator?.choose(.dismiss, event: nil) }
        }
    }

    func refreshStatus() async { status = await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async { _ = try? await center.requestAuthorization(options: [.alert, .sound]); await refreshStatus() }

    func present(_ events: [CalendarEvent]) { route(events) }
    func update(_ events: [CalendarEvent]) { panel.isVisible ? panel.update(events) : route(events) }

    func dismiss() {
        panel.close()
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
    }

    private func route(_ events: [CalendarEvent]) {
        if NSApp.isActive || !canNotify { panel.show(events); return }
        let c = UNMutableNotificationContent()
        c.sound = .default
        if events.count == 1, let e = events.first {
            c.title = e.snapshot.title
            c.body = "Starts at " + e.snapshot.start.formatted(date: .omitted, time: .shortened) + ". Click to record."
        } else {
            c.title = "\(events.count) meetings starting soon"
            c.body = events.map(\.snapshot.title).joined(separator: ", ") + ". Click to choose and record."
        }
        center.add(UNNotificationRequest(identifier: notificationID, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            guard let visible = coordinator?.visible, !visible.isEmpty else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.show(visible)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
