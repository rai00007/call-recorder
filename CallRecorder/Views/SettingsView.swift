import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var ollamaResult = ""
    @State private var importResult = ""
    private let languages = ["en-US", "en-GB", "en-AU", "en-IN", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "ko-KR", "zh-CN"]

    var body: some View {
        let s = state.settings
        Form {
            Section("Storage") {
                LabeledContent("Recordings folder") {
                    Text(s.storageURL.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose…") { choose() }
                    Button("Reset to default") { s.storagePath = "" }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.storageURL]) }
                }
                Text("Applies to new recordings. Recordings in the previous folder are not moved or deleted; switch back to see them.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Import recordings from the old recordings/ folder") {
                        Task { let n = await state.store.importLegacy(from: AppState.legacyDir); importResult = "Imported \(n) recording(s) (copied; originals untouched)." }
                    }
                    Text(importResult).font(.caption)
                }
                Toggle("Ask me about deleting raw mic/system tracks after processing", isOn: Binding(get: { s.askAboutRawTracks }, set: { s.askAboutRawTracks = $0 }))
            }
            Section("Transcription") {
                Picker("Language", selection: Binding(get: { s.language }, set: { s.language = $0 })) {
                    ForEach(Array(Set(languages + [s.language])).sorted(), id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) }
                }
            }
            Section("Meeting minutes (Ollama, optional)") {
                TextField("Endpoint", text: Binding(get: { s.ollamaURL }, set: { s.ollamaURL = $0 }))
                TextField("Model", text: Binding(get: { s.ollamaModel }, set: { s.ollamaModel = $0 }))
                Toggle("Summarize automatically after transcription", isOn: Binding(get: { s.autoSummarize }, set: { s.autoSummarize = $0 }))
                HStack {
                    Button("Test connection") {
                        Task {
                            do { try await OllamaService(baseURL: s.ollamaBaseURL, model: s.ollamaModel).check(); ollamaResult = "Ollama is reachable and the model is installed." }
                            catch { ollamaResult = error.localizedDescription }
                        }
                    }
                    Text(ollamaResult).font(.caption)
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { loginOn }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = "" }
                    catch { loginError = error.localizedDescription }
                    loginOn = SMAppService.mainApp.status == .enabled
                }))
                if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section("Permissions & troubleshooting") {
                LabeledContent("Microphone", value: micText)
                LabeledContent("Screen & System Audio Recording", value: Permissions.screenGranted ? "Granted" : "Not granted (or relaunch needed)")
                HStack {
                    Button("Open Microphone settings") { open("Privacy_Microphone") }
                    Button("Open Screen Recording settings") { open("Privacy_ScreenCapture") }
                }
                Text("• Nothing records until you click Start. • If you just granted access, quit and reopen Call Recorder. • Use headphones to avoid your mic re-recording the other side. • Rebuilding with an ad-hoc signature resets permissions; see the README. • Summaries need Ollama running with the model pulled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 560, height: 620)
    }

    private var micText: String {
        switch Permissions.micStatus { case .authorized: "Granted"; case .denied: "Denied"; case .restricted: "Restricted"; default: "Not asked yet" }
    }
    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    private func choose() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { state.settings.storagePath = u.path }
    }
}
