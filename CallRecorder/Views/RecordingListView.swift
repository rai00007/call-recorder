import SwiftUI

struct RecordingListView: View {
    @EnvironmentObject var state: AppState
    @Binding var showStorage: Bool
    @State private var renaming: UUID?
    @State private var newTitle = ""
    @State private var deleting: Set<UUID> = []

    var body: some View {
        let items = state.store.search(state.searchText)
        List(items, selection: $state.selection) { m in
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.headline).lineLimit(1)
                HStack {
                    Text(m.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("· " + formatDuration(m.duration))
                    Spacer()
                    Text(m.statusLabel).foregroundStyle(m.transcript.isFailed || m.summary.isFailed || m.needsRecovery ? .orange : .secondary)
                }.font(.caption).foregroundStyle(.secondary)
            }
            .tag(m.id)
        }
        // Native double-click + right-click handling; unlike a per-row tap gesture it doesn't interfere with single-click selection.
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, ids.count == 1 {
                Button("Open in New Window") { state.openRecordingWindow(id) }
                Button("Rename…") { renaming = id; newTitle = state.store.meta(id)?.title ?? "" }
            }
            if !ids.isEmpty { Button("Delete…", role: .destructive) { deleting = ids } }
        } primaryAction: { ids in
            if let id = ids.first { state.openRecordingWindow(id) }
        }
        .searchable(text: $state.searchText, prompt: "Search titles and transcripts")
        .overlay { if items.isEmpty { Text(state.searchText.isEmpty ? "No recordings yet" : "No matches").foregroundStyle(.secondary) } }
        .toolbar {
            ToolbarItem { Button("Manage storage", systemImage: "externaldrive") { showStorage = true } }
        }
        .alert("Rename recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let id = renaming { state.store.rename(id, to: newTitle) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move \(deleting.count) recording(s) and their transcripts/minutes to the Trash?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Move to Trash", role: .destructive) {
                for id in deleting { try? state.store.delete(id) }
                state.selection.subtract(deleting); deleting = []
            }
        }
    }
}

/// Bulk, user-initiated cleanup. Raw mic/system tracks are never removed automatically.
struct StorageManagementView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var days = 30
    @State private var pending: (title: String, ids: [UUID])?
    @State private var result = ""

    private var store: RecordingStore { state.store }
    private func bytes(_ ids: [UUID]) -> String { ByteCountFormatter.string(fromByteCount: ids.reduce(0) { $0 + store.rawBytes($1) }, countStyle: .file) }

    var body: some View {
        let all = store.rawCleanupCandidates(.all)
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage storage").font(.title2)
            Text("Each recording keeps separate microphone and system-audio tracks (used for Me/Others transcripts) next to the mixed audio. They use \(bytes(all)) across \(all.count) recordings. Removing them moves only those two files to the Trash; the mixed audio, transcript and minutes stay. Transcription can then only be retried from the mixed audio, without Me/Others labels.")
                .font(.callout).foregroundStyle(.secondary)
            row("Selected recordings", .selected(state.selection))
            HStack {
                row("Older than", .olderThan(days: days, now: Date()))
                Picker("", selection: $days) { ForEach([7, 30, 90], id: \.self) { Text("\($0) days").tag($0) } }.labelsHidden().frame(width: 110)
            }
            row("Already transcribed", .transcribed)
            row("All recordings", .all)
            if !result.isEmpty { Text(result).font(.callout) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Move raw tracks to Trash", role: .destructive) {
                if let ids = pending?.ids {
                    Task {
                        let r = await store.deleteRawTracks(ids)
                        result = "Removed raw tracks from \(r.count) recording(s), freeing \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))."
                    }
                }
                pending = nil
            }
        }
    }

    private func row(_ label: String, _ f: RawCleanupFilter) -> some View {
        let ids = store.rawCleanupCandidates(f)
        return HStack {
            Text(label); Text("(\(ids.count), \(bytes(ids)))").foregroundStyle(.secondary)
            Spacer()
            Button("Delete raw tracks…") {
                pending = ("Move raw tracks of \(ids.count) recording(s) (\(bytes(ids))) to the Trash?", ids)
            }.disabled(ids.isEmpty)
        }
    }
}
