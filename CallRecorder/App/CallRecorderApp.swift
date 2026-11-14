import SwiftUI
import AppKit

@main
struct CallRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Call Recorder", id: "main") {
            MainWindow().environmentObject(state).optaraWindow()
        }
        .defaultSize(width: 980, height: 640)
        WindowGroup("Recording", id: "recording", for: UUID.self) { $id in
            if let id { RecordingDetailView(id: id).environmentObject(state).frame(minWidth: 560, minHeight: 420).optaraWindow() }
        }
        Settings { SettingsView().environmentObject(state) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ n: Notification) {
        let state = AppState.shared
        menuBar = MenuBarController(state: state)
        Task { await state.startup() }
        let nc = NotificationCenter.default
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.prompts.refresh() }   // after sleep: prompt if the reminder window is open, never for meetings underway
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppState.shared.notifier.refreshStatus(); AppState.shared.prompts.refresh() }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in NotesAutosaver.flushAll() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppState.shared.openMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        NotesAutosaver.flushAll()
        let m = AppState.shared.manager
        switch m.state {
        case .recording, .starting, .stopping, .processing:
            Task { await m.prepareForQuit(); NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        default: return .terminateNow
        }
    }
}
