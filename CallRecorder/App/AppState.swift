import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    let settings = AppSettings()
    let store: RecordingStore
    let pipeline: ProcessingPipeline
    let manager: RecordingManager
    @Published var selection: Set<UUID> = []
    @Published var searchText = ""
    @Published var showConsent = false
    var openMainWindow: () -> Void = {}
    var openRecordingWindow: (UUID) -> Void = { _ in }
    private var bag = Set<AnyCancellable>()

    init() {
        store = RecordingStore(root: settings.storageURL)
        pipeline = ProcessingPipeline(store: store, settings: settings)
        manager = RecordingManager(store: store, pipeline: pipeline, settings: settings)
        // Forward child changes so views only observe AppState.
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settings.$storagePath.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.store.setRoot(self.settings.storageURL); self.selection = [] }
        }.store(in: &bag)
    }

    static var legacyDir: URL { Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("recordings") }

    func startup() async {
        store.load()
        if !UserDefaults.standard.bool(forKey: "legacyImportDone") {
            await store.importLegacy(from: Self.legacyDir)
            UserDefaults.standard.set(true, forKey: "legacyImportDone")
        }
        await manager.recoverInterrupted()
    }

    /// Recording only ever starts from an explicit user action, after the consent reminder was acknowledged once.
    func requestStart() {
        if settings.consentAcknowledged { Task { await manager.start() } }
        else { showConsent = true; openMainWindow() }
    }
    func acknowledgeConsentAndStart() { settings.consentAcknowledged = true; showConsent = false; Task { await manager.start() } }
    func requestStop() { Task { await manager.stop() } }

    func show(_ id: UUID) { selection = [id]; openMainWindow() }
}
