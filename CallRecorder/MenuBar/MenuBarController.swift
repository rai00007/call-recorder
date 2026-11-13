import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state: AppState
    private var bag = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        super.init()
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        state.manager.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }.store(in: &bag)
        render()
    }

    private var recording: Bool { state.manager.state == .recording }

    private func render() {
        item.button?.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "record.circle", accessibilityDescription: "Call Recorder")
        item.button?.contentTintColor = recording ? .systemRed : nil
        item.button?.title = recording ? " " + formatDuration(state.manager.elapsed) : ""
    }

    private var statusText: String {
        switch state.manager.state {
        case .idle, .completed: return "Idle"
        case .starting: return "Starting…"
        case .recording: return "Recording — " + formatDuration(state.manager.elapsed)
        case .stopping: return "Saving…"
        case .processing: return "Finishing…"
        case .failed(let m): return "Failed: " + String(m.prefix(60))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = NSMenuItem(title: statusText, action: nil, keyEquivalent: ""); s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())
        let busy = !state.manager.state.canStart && !recording
        let toggle = NSMenuItem(title: recording ? "Stop Recording" : "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self; toggle.isEnabled = !busy
        menu.addItem(toggle)
        menu.addItem(.separator())
        add(menu, "Open Call Recorder", #selector(openMain), "o")
        let recent = state.store.recordings.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let h = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: ""); h.isEnabled = false
            menu.addItem(h)
            for m in recent {
                let i = NSMenuItem(title: "\(m.title) (\(formatDuration(m.duration)))", action: #selector(openRecording(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = m.id
                menu.addItem(i)
            }
        }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), ",")
        add(menu, "Quit", #selector(quit), "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self; menu.addItem(i)
    }

    @objc private func toggleRecording() { recording ? state.requestStop() : state.requestStart() }
    @objc private func openMain() { state.openMainWindow() }
    @objc private func openRecording(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { state.show(id) } }
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
