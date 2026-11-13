import SwiftUI
import AppKit

@main
struct CallRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Call Recorder", id: "main") {
            MainWindow().environmentObject(state)
        }
        .defaultSize(width: 980, height: 640)
        WindowGroup("Recording", id: "recording", for: UUID.self) { $id in
            if let id { RecordingDetailView(id: id).environmentObject(state).frame(minWidth: 560, minHeight: 420) }
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppState.shared.openMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        let m = AppState.shared.manager
        switch m.state {
        case .recording, .starting, .stopping, .processing:
            Task { await m.prepareForQuit(); NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        default: return .terminateNow
        }
    }
}
