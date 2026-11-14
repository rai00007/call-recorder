import SwiftUI

/// Autosaving handwritten notes. Stored apart from transcript and minutes, so regenerating a summary never touches them.
struct NotesEditor: View {
    let url: URL
    let exportName: String
    @StateObject private var saver: NotesAutosaver
    @State private var text = ""

    init(url: URL, exportName: String) {
        self.url = url; self.exportName = exportName
        _saver = StateObject(wrappedValue: NotesAutosaver(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(saver.isSaved ? "Saved" : "Saving…").font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button { copyToPasteboard(text) } label: { Label("Copy notes", systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                    .buttonStyle(SecondaryButtonStyle()).disabled(text.isEmpty).help("Copy notes")
                Button { exportFile(name: exportName + " notes.md", text: Exporter.notes(title: exportName, text: text)) } label: { Label("Export notes", systemImage: "square.and.arrow.up").labelStyle(.iconOnly) }
                    .buttonStyle(SecondaryButtonStyle()).disabled(text.isEmpty).help("Export notes")
            }
            TextEditor(text: Binding(get: { text }, set: { text = $0; saver.edit($0) }))
                .font(.body).scrollContentBackground(.hidden).padding(8)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                .accessibilityLabel("Meeting notes")
        }
        .onAppear { text = saver.load() }
        .onDisappear { saver.flush() }
    }
}

/// Meeting title, date, calendar and invitees shown above the content.
struct MeetingHeader: View {
    let snapshot: MeetingSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(Theme.accent)
                Text(DateLabel.range(snapshot) + (snapshot.calendarName.map { " · " + $0 } ?? ""))
            }
            if !snapshot.invitees.isEmpty {
                let names = snapshot.invitees.map(\.name)
                Text("Invited (from calendar): " + names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " +\(names.count - 6) more" : ""))
                    .lineLimit(2)
            }
            if let link = snapshot.joinLink {
                Link(destination: link) { Label(link.host ?? "Join link", systemImage: "link") }.foregroundStyle(Theme.accent)
            }
        }
        .font(.caption).foregroundStyle(Theme.secondary)
    }
}
