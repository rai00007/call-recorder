import SwiftUI

/// A meeting with or without recordings: notes can be taken before, during or after, even if nothing is ever recorded.
struct MeetingDetailView: View {
    @EnvironmentObject var state: AppState
    let id: UUID

    private var snapshot: MeetingSnapshot? {
        state.meetings.meeting(id)?.snapshot ?? state.prompts.upcoming.first { $0.id == id }?.snapshot
    }

    var body: some View {
        if let s = snapshot {
            let recordings = state.store.recordings.filter { $0.meeting?.meetingId == id }
            VStack(alignment: .leading, spacing: 12) {
                Text(s.title).font(.title2.bold()).lineLimit(2)
                MeetingHeader(snapshot: s)
                if state.manager.state.canStart {
                    HStack {
                        if s.joinLink != nil { Button("Join & Record") { start(openLink: true) }.buttonStyle(PrimaryButtonStyle()) }
                        Button("Record Only") { start(openLink: false) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                Text("Notes").font(.headline)
                NotesEditor(url: state.meetings.notesURL(id), exportName: s.title).id(id)
                if !recordings.isEmpty {
                    Text("Recordings").font(.headline)
                    ForEach(recordings) { r in
                        Button { state.selection = [r.id] } label: {
                            HStack { Image(systemName: "waveform"); Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)); Text(formatDuration(r.duration)).foregroundStyle(Theme.secondary); Spacer(); Text(r.statusLabel).foregroundStyle(Theme.secondary) }
                        }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else { Text("Meeting not found").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func start(openLink: Bool) {
        if let e = state.prompts.upcoming.first(where: { $0.id == id }) { state.requestStart(meeting: e.link, openLink: openLink) }
        else if let m = state.meetings.meeting(id) {
            state.requestStart(meeting: MeetingLink(meetingId: m.id, occurrenceKey: m.occurrenceKey, ref: m.ref, snapshot: m.snapshot), openLink: openLink)
        }
    }
}
