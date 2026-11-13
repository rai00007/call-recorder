import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showStorage = false

    var body: some View {
        VStack(spacing: 0) {
            RecordingBar()
            Divider()
            NavigationSplitView {
                RecordingListView(showStorage: $showStorage)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } detail: {
                if state.selection.count == 1, let id = state.selection.first {
                    RecordingDetailView(id: id).id(id)
                } else {
                    Text(state.selection.count > 1 ? "\(state.selection.count) recordings selected" : "Select a recording")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
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
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Laws on recording calls vary and some require every participant's consent. Tell people you're recording. You are responsible for complying with the law. Audio stays on this Mac.")
        }
    }
}

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
                Label(formatDuration(m.elapsed), systemImage: "record.circle.fill").foregroundStyle(.red).monospacedDigit()
                sourceLabel("Mic", "mic.fill", m.micStatus)
                sourceLabel("System audio", "speaker.wave.2.fill", m.systemStatus)
                if m.droppedBuffers > 0 { Text("\(m.droppedBuffers) dropped").foregroundStyle(.orange).font(.caption) }
            case .starting: ProgressView().controlSize(.small); Text("Starting…")
            case .stopping, .processing: ProgressView().controlSize(.small); Text("Saving recording…")
            case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2).font(.caption)
            default: Text("Not recording").foregroundStyle(.secondary)
            }
            if let p = processing { ProgressView().controlSize(.small); Text(p).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if m.state == .recording {
                Button("Stop Recording", systemImage: "stop.fill") { state.requestStop() }.tint(.red)
            } else {
                Button("Start Recording", systemImage: "record.circle") { state.requestStart() }
                    .disabled(!m.state.canStart)
            }
        }
        .padding(10)
    }

    private func sourceLabel(_ name: String, _ icon: String, _ s: SourceStatus) -> some View {
        let (text, color): (String, Color) = switch s {
        case .active: ("active", .green)
        case .waiting: ("waiting…", .secondary)
        case .silent: ("no audio", .orange)
        case .off: ("off", .secondary)
        }
        return Label("\(name): \(text)", systemImage: icon).foregroundStyle(color).font(.caption)
    }
}
