import SwiftUI
import AppKit

@MainActor
final class PromptModel: ObservableObject {
    @Published var events: [CalendarEvent] = []
    @Published var selected: UUID?
    var choose: (PromptAction, CalendarEvent?) -> Void = { _, _ in }
}

struct MeetingPromptView: View {
    @ObservedObject var model: PromptModel

    private var current: CalendarEvent? { model.events.first { $0.id == model.selected } ?? model.events.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Meeting starting soon", systemImage: "calendar").font(.caption).foregroundStyle(Theme.secondary)
            if model.events.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.events) { e in
                        Button { model.selected = e.id } label: {
                            HStack {
                                Image(systemName: e.id == (current?.id) ? "largecircle.fill.circle" : "circle").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading) {
                                    Text(e.snapshot.title).lineLimit(1)
                                    Text(timeText(e)).font(.caption).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(e.id == current?.id ? .isSelected : [])
                    }
                }
            } else if let e = current {
                Text(e.snapshot.title).font(.headline).lineLimit(2)
                Text(timeText(e)).font(.callout).foregroundStyle(Theme.secondary)
            }
            HStack {
                Button("Join & Record") { model.choose(.joinAndRecord, current) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                Button("Record Only") { model.choose(.recordOnly, current) }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Dismiss") { model.choose(.dismiss, nil) }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Text("Nothing records until you choose Join & Record or Record Only.").font(.caption2).foregroundStyle(Theme.secondary)
        }
        .padding(16).frame(width: 380).foregroundStyle(Theme.text).background(Theme.bg).tint(Theme.accent).preferredColorScheme(.dark)
    }

    private func timeText(_ e: CalendarEvent) -> String {
        e.snapshot.start.formatted(date: .omitted, time: .shortened) + " – " + e.snapshot.end.formatted(date: .omitted, time: .shortened)
    }
}

/// Small floating navy panel used while the app is in the foreground, or when notifications are not allowed.
@MainActor
final class MeetingPromptPanel: NSObject, NSWindowDelegate {
    let model = PromptModel()
    var onUserClosed: () -> Void = {}
    private var panel: NSPanel?
    private var closingProgrammatically = false
    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ events: [CalendarEvent]) {
        apply(events)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200), styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
            p.title = "Meeting starting soon"; p.titlebarAppearsTransparent = true; p.titleVisibility = .hidden
            p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
            p.backgroundColor = NSColor(red: 0x11 / 255, green: 0x1B / 255, blue: 0x27 / 255, alpha: 1)
            p.appearance = NSAppearance(named: .darkAqua); p.delegate = self
            p.contentView = NSHostingView(rootView: MeetingPromptView(model: model))
            panel = p
        }
        guard let p = panel else { return }
        p.setContentSize(p.contentView?.fittingSize ?? p.frame.size)
        if !p.isVisible, let s = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: s.visibleFrame.maxX - p.frame.width - 20, y: s.visibleFrame.maxY - p.frame.height - 20))
        }
        p.orderFrontRegardless()
    }

    func update(_ events: [CalendarEvent]) { apply(events); if let p = panel { p.setContentSize(p.contentView?.fittingSize ?? p.frame.size) } }

    private func apply(_ events: [CalendarEvent]) {
        model.events = events
        if model.selected == nil || !events.contains(where: { $0.id == model.selected }) { model.selected = events.first?.id }
    }

    func close() {
        closingProgrammatically = true
        panel?.close()
        closingProgrammatically = false
    }

    func windowWillClose(_ notification: Notification) { if !closingProgrammatically { onUserClosed() } }
}
