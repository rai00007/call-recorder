import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showStorage = false

    var body: some View {
        NavigationSplitView {
            RecordingListView(showStorage: $showStorage)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if state.settings.meetingPromptsEnabled && state.prompts.access != .granted { CalendarBanner() }
                RecordingBar()
                Divider().overlay(Theme.border)
                if state.selection.count == 1, let id = state.selection.first {
                    if state.store.meta(id) != nil { RecordingDetailView(id: id).id(id) } else { MeetingDetailView(id: id).id(id) }
                } else {
                    Text(state.selection.count > 1 ? "\(state.selection.count) items selected" : "Select a recording or meeting")
                        .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.bg)
        }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear {
            state.openMainWindow = {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            state.openRecordingWindow = { openWindow(id: "recording", value: $0) }
        }
        .sheet(isPresented: $showStorage) { StorageManagementView().environmentObject(state) }
        .alert("Recording consent", isPresented: $state.showConsent) {
            Button("I understand — start recording") { state.acknowledgeConsentAndStart() }
            Button("Cancel", role: .cancel) { state.cancelConsent() }
        } message: {
            Text("Laws on recording calls vary and some require every participant's consent. Tell people you're recording. You are responsible for complying with the law. Audio stays on this Mac.")
        }
    }
}

private struct CalendarBanner: View {
    var body: some View {
        HStack {
            Label("Calendar access is off, so meeting prompts are paused.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Spacer()
            Button("Open Calendar settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
                .buttonStyle(SecondaryButtonStyle())
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(Theme.panel)
    }
}

/// Persistent bar: red indicator, timer, audio level and Stop while recording.
struct RecordingBar: View {
    @EnvironmentObject var state: AppState

    private var processing: String? {
        for m in state.store.recordings {
            if m.transcript == .running { return "Transcribing “\(m.title)”…" }
            if m.summary == .running { return "Summarizing “\(m.title)”…" }
        }
        return nil
    }

    var body: some View {
        let m = state.manager
        HStack(spacing: 14) {
            switch m.state {
            case .recording:
                HStack(spacing: 6) {
                    Circle().fill(Theme.danger).frame(width: 9, height: 9).accessibilityHidden(true)
                    Text(formatDuration(m.elapsed)).monospacedDigit().font(.callout.weight(.semibold))
                }.accessibilityElement(children: .combine).accessibilityLabel("Recording").accessibilityValue(formatDuration(m.elapsed))
                LevelMeter(level: min(1, m.level))
                sourceLabel("Mic", "mic.fill", m.micStatus)
                sourceLabel("System", "speaker.wave.2.fill", m.systemStatus)
                if m.droppedBuffers > 0 { Text("\(m.droppedBuffers) dropped").foregroundStyle(.orange).font(.caption) }
            case .starting: ProgressView().controlSize(.small); Text("Starting…")
            case .stopping, .processing: ProgressView().controlSize(.small); Text("Saving recording…")
            case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2).font(.caption)
            default: Text("Not recording").foregroundStyle(Theme.secondary)
            }
            if let p = processing { ProgressView().controlSize(.small); Text(p).font(.caption).foregroundStyle(Theme.secondary) }
            Spacer()
            if m.state == .recording {
                if let id = m.currentRecordingID { Button("Notes", systemImage: "note.text") { state.selection = [id] }.buttonStyle(SecondaryButtonStyle()) }
                Button("Stop", systemImage: "stop.fill") { state.requestStop() }.buttonStyle(DangerButtonStyle())
                    .accessibilityLabel("Stop recording")
            } else {
                Button("Start Recording", systemImage: "record.circle") { state.requestStart() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!m.state.canStart)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).background(Theme.panel)
    }

    private func sourceLabel(_ name: String, _ icon: String, _ s: SourceStatus) -> some View {
        let (text, color): (String, Color) = switch s {
        case .active: ("active", Theme.accent)
        case .waiting: ("waiting…", Theme.secondary)
        case .silent: ("no audio", .orange)
        case .off: ("off", Theme.secondary)
        }
        return Label("\(name): \(text)", systemImage: icon).foregroundStyle(color).font(.caption)
    }
}
