import SwiftUI
import AppKit

/// Compact sidebar: logo, Upcoming meetings, then recordings (and meetings with notes) grouped by date.
struct RecordingListView: View {
    @EnvironmentObject var state: AppState
    @Binding var showStorage: Bool
    @State private var renaming: UUID?
    @State private var newTitle = ""
    @State private var deleting: Set<UUID> = []
    @FocusState private var listFocused: Bool

    private enum Entry: Identifiable {
        case recording(RecordingMetadata), meeting(Meeting)
        var id: UUID { switch self { case .recording(let m): m.id; case .meeting(let m): m.id } }
        var date: Date { switch self { case .recording(let m): m.createdAt; case .meeting(let m): m.snapshot.start } }
    }

    private var upcoming: [CalendarEvent] {
        let q = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.prompts.upcoming.filter { q.isEmpty || $0.snapshot.title.localizedCaseInsensitiveContains(q) }
    }

    private var groups: [(day: Date, entries: [Entry])] {
        let recs = state.store.search(state.searchText)
        let q = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let linked = Set(state.store.recordings.compactMap { $0.meeting?.meetingId })
        let upcomingIDs = Set(state.prompts.upcoming.map(\.id))
        let metas = state.meetings.meetings.filter { !linked.contains($0.id) && !upcomingIDs.contains($0.id) && (q.isEmpty || $0.snapshot.title.localizedCaseInsensitiveContains(q)) }
        let all: [Entry] = recs.map(Entry.recording) + metas.map(Entry.meeting)
        let byDay = Dictionary(grouping: all) { Calendar.current.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0]!.sorted { $0.date > $1.date }) }
    }

    private var orderedIDs: [UUID] { upcoming.map(\.id) + groups.flatMap { $0.entries.map(\.id) } }

    var body: some View {
        let ups = upcoming, grps = groups
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                OptaraLogo(height: 26)
                Text("Call Recorder").font(.callout.weight(.semibold))
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search titles and transcripts", text: $state.searchText).textFieldStyle(.plain)
            }
            .padding(7).background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
            .padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !ups.isEmpty {
                        header("Upcoming meetings")
                        ForEach(ups) { e in
                            row(e.id, icon: "calendar", title: e.snapshot.title,
                                subtitle: e.snapshot.start.formatted(date: .omitted, time: .shortened) + " · " + (e.snapshot.calendarName ?? ""), warn: false, trailing: nil)
                        }
                    }
                    ForEach(grps, id: \.day) { g in
                        header(DateLabel.day(g.day))
                        ForEach(g.entries) { entry in
                            switch entry {
                            case .recording(let m):
                                row(m.id, icon: m.meeting != nil ? "person.2.wave.2" : "waveform", title: m.title,
                                    subtitle: m.createdAt.formatted(date: .omitted, time: .shortened) + " · " + formatDuration(m.duration),
                                    warn: m.transcript.isFailed || m.summary.isFailed || m.needsRecovery, trailing: m.statusLabel)
                            case .meeting(let m):
                                row(m.id, icon: "calendar", title: m.snapshot.title, subtitle: m.snapshot.start.formatted(date: .omitted, time: .shortened) + " · notes", warn: false, trailing: nil)
                            }
                        }
                    }
                    if ups.isEmpty && grps.isEmpty {
                        Text(state.searchText.isEmpty ? "No recordings yet" : "No matches").foregroundStyle(Theme.secondary).padding(20).frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, 6).padding(.bottom, 8)
            }
            .focusable().focused($listFocused).focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.return) { if let id = state.selection.first, state.store.meta(id) != nil { state.openRecordingWindow(id) }; return .handled }
            Divider().overlay(Theme.border)
            HStack {
                Button("Manage storage", systemImage: "externaldrive") { showStorage = true }.buttonStyle(.plain).foregroundStyle(Theme.secondary).font(.caption)
                Spacer()
            }.padding(10)
        }
        .background(Theme.panel)
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

    private func header(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2).accessibilityAddTraits(.isHeader)
    }

    private func row(_ id: UUID, icon: String, title: String, subtitle: String, warn: Bool, trailing: String?) -> some View {
        let selected = state.selection.contains(id)
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(selected ? Theme.accent : Theme.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).font(.callout)
                Text(subtitle).lineLimit(1).font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            if let t = trailing, warn { Text(t).font(.caption2).foregroundStyle(.orange).lineLimit(1) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2).padding(.vertical, 4) } }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { if state.store.meta(id) != nil { state.openRecordingWindow(id) } })
        .simultaneousGesture(TapGesture().onEnded {
            listFocused = true
            if NSEvent.modifierFlags.contains(.command) {
                if state.selection.contains(id) { state.selection.remove(id) } else { state.selection.insert(id) }
            } else { state.selection = [id] }
        })
        .contextMenu {
            if state.store.meta(id) != nil {
                Button("Open in New Window") { state.openRecordingWindow(id) }
                Button("Rename…") { renaming = id; newTitle = state.store.meta(id)?.title ?? "" }
                Button("Delete…", role: .destructive) { deleting = state.selection.contains(id) ? state.selection.filter { state.store.meta($0) != nil } : [id] }
            }
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func move(_ d: Int) {
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        let cur = state.selection.first.flatMap { ids.firstIndex(of: $0) } ?? (d > 0 ? -1 : ids.count)
        state.selection = [ids[max(0, min(ids.count - 1, cur + d))]]
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
