import SwiftUI
import AppKit

func copyToPasteboard(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

@MainActor func exportFile(name: String, text: String) {
    let p = NSSavePanel(); p.nameFieldStringValue = name
    if p.runModal() == .OK, let u = p.url { try? Exporter.write(text, to: u) }
}

struct RecordingDetailView: View {
    @EnvironmentObject var state: AppState
    let id: UUID
    @State private var title = ""

    var body: some View {
        if let m = state.store.meta(id) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Title", text: $title).textFieldStyle(.plain).font(.title2.bold())
                        .onSubmit { state.store.rename(id, to: title) }
                    Text(m.statusLabel).foregroundStyle(.secondary)
                }
                Text(m.createdAt.formatted(date: .complete, time: .shortened) + " · " + formatDuration(m.duration))
                    .font(.caption).foregroundStyle(.secondary)
                if let n = m.note { Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                TabView {
                    SummaryTab(m: m).tabItem { Label("Summary", systemImage: "doc.text") }
                    TranscriptTab(m: m).tabItem { Label("Transcript", systemImage: "text.bubble") }
                    AudioTab(m: m).tabItem { Label("Audio", systemImage: "waveform") }
                    ActionsTab(m: m).tabItem { Label("Actions", systemImage: "checklist") }
                }
            }
            .padding()
            .onAppear { title = m.title }
        } else { Text("Recording not found").foregroundStyle(.secondary) }
    }
}

private struct StepBanner: View {
    let status: StepStatus
    let running: String
    var retry: (String, () -> Void)?
    var body: some View {
        switch status {
        case .running: HStack { ProgressView().controlSize(.small); Text(running) }
        case .failed(let msg):
            HStack { Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                if let retry { Button(retry.0, action: retry.1) } }
        default: EmptyView()
        }
    }
}

private struct SummaryTab: View {
    @EnvironmentObject var state: AppState
    let m: RecordingMetadata
    var body: some View {
        let md = state.store.read(m.id, .minutes)
        VStack(alignment: .leading) {
            HStack {
                StepBanner(status: m.summary, running: "Writing minutes…", retry: ("Retry summary", { Task { await state.pipeline.summarize(m.id) } }))
                Spacer()
                if m.summary != .running {
                    Button(md.isEmpty ? "Generate summary" : "Regenerate") { Task { await state.pipeline.summarize(m.id) } }
                        .disabled(m.transcript != .done)
                }
                Button("Copy") { copyToPasteboard(md) }.disabled(md.isEmpty)
                Button("Export…") { exportFile(name: m.title + " minutes.md", text: md) }.disabled(md.isEmpty)
            }
            ScrollView {
                Text(md.isEmpty ? "No minutes yet. Minutes need a transcript and a running Ollama (optional)." : md)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TranscriptTab: View {
    @EnvironmentObject var state: AppState
    let m: RecordingMetadata
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        let text = state.store.transcriptText(m.id)
        let edited = state.store.exists(m.id, .edited)
        VStack(alignment: .leading) {
            HStack {
                StepBanner(status: m.transcript, running: "Transcribing…", retry: ("Retry transcription", { Task { await state.pipeline.transcribe(m.id) } }))
                if edited { Text("Edited").font(.caption).padding(.horizontal, 6).background(.quaternary, in: Capsule()) }
                Spacer()
                if m.transcript != .running {
                    Button(text.isEmpty ? "Transcribe" : "Re-transcribe") { Task { await state.pipeline.transcribe(m.id) } }
                }
                if editing {
                    Button("Save") { try? state.store.write(draft, m.id, .edited); editing = false }
                    Button("Cancel") { editing = false }
                } else {
                    Button("Edit") { draft = text; editing = true }.disabled(text.isEmpty)
                    if edited { Button("Revert to original") { try? FileManager.default.removeItem(at: state.store.url(m.id, .edited)); state.objectWillChange.send() } }
                }
                Button("Copy") { copyToPasteboard(text) }.disabled(text.isEmpty)
                Button("Export…") { exportFile(name: m.title + " transcript.txt", text: text) }.disabled(text.isEmpty)
            }
            if editing {
                TextEditor(text: $draft).font(.body.monospaced())
            } else {
                let lines = TranscriptFormat.parse(text)
                if lines.isEmpty {
                    ScrollView { Text(text.isEmpty ? "No transcript yet." : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    List(Array(lines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .top) {
                            Text(l.stamp).monospacedDigit().foregroundStyle(.secondary)
                            Text(l.who).bold().foregroundStyle(l.who == "Me" ? Color.accentColor : .primary).frame(width: 60, alignment: .leading)
                            Text(l.text).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

private struct AudioTab: View {
    @EnvironmentObject var state: AppState
    let m: RecordingMetadata
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.store.exists(m.id, .audio) {
                AudioPlayerView(url: state.store.url(m.id, .audio)).id(m.id)
            } else { Text("No mixed audio file for this recording.").foregroundStyle(.secondary) }
            Divider()
            let raw = state.store.rawBytes(m.id)
            if raw > 0 {
                Text("Separate mic/system tracks: \(ByteCountFormatter.string(fromByteCount: raw, countStyle: .file)). Kept so transcription can label Me/Others.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Delete raw tracks…") { confirm = true }.disabled(m.needsRecovery)
            } else if m.rawTracksRemoved {
                Text("Raw tracks were removed. Re-transcription uses the mixed audio without Me/Others labels.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .confirmationDialog("Move this recording's raw mic/system tracks to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { Task { await state.store.deleteRawTracks([m.id]) } }
        }
    }
}

private struct ActionsTab: View {
    @EnvironmentObject var state: AppState
    let m: RecordingMetadata

    private func edit(_ change: @escaping (inout [ActionItem]) -> Void) {
        state.store.update(m.id) { change(&$0.actionItems); $0.actionItemsEdited = true }
    }
    private func binding(_ item: ActionItem, _ kp: WritableKeyPath<ActionItem, String?>) -> Binding<String> {
        Binding(get: { item.owner == nil && kp == \ActionItem.owner ? "" : (item[keyPath: kp] ?? "") },
                set: { v in edit { items in if let i = items.firstIndex(where: { $0.id == item.id }) { items[i][keyPath: kp] = v.isEmpty ? nil : v } } })
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Edit or remove items before exporting. Owners and due dates appear only if stated in the meeting.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add") { edit { $0.append(ActionItem(text: "New action item")) } }
                Button("Re-extract from minutes") { Task { await state.pipeline.summarize(m.id, regenerateActions: true) } }.disabled(m.transcript != .done)
                Button("Copy") { copyToPasteboard(Exporter.actions(m)) }.disabled(m.actionItems.isEmpty)
                Button("Export…") { exportFile(name: m.title + " actions.md", text: Exporter.actions(m)) }.disabled(m.actionItems.isEmpty)
            }
            if m.actionItems.isEmpty { Text("No action items.").foregroundStyle(.secondary).padding(.top) }
            List(m.actionItems) { item in
                HStack {
                    Toggle("", isOn: Binding(get: { item.done }, set: { v in edit { items in if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].done = v } } })).labelsHidden()
                    TextField("Task", text: Binding(get: { item.text }, set: { v in edit { items in if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].text = v } } }))
                    TextField("Owner", text: binding(item, \.owner)).frame(width: 110)
                    TextField("Due", text: binding(item, \.due)).frame(width: 110)
                    if let r = item.sourceRef { Text("@\(r)").font(.caption).foregroundStyle(.secondary) }
                    Button("Remove", systemImage: "trash") { edit { items in items.removeAll { $0.id == item.id } } }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
    }
}
