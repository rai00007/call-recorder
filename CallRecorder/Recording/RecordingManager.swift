import Foundation

enum RecorderState: Equatable {
    case idle, starting, recording, stopping, processing
    case completed(UUID)
    case failed(String)
    var canStart: Bool {
        switch self { case .idle, .completed, .failed: return true; default: return false }
    }
}

enum SourceStatus { case off, waiting, active, silent }

/// Owns the recording lifecycle. The state is changed synchronously before any `await`, so repeated
/// Start/Stop calls are ignored. Audio is written into the recording folder from the first buffer
/// and is never deleted here.
@MainActor
final class RecordingManager: ObservableObject {
    typealias Factory = (_ system: URL, _ mic: URL) throws -> CaptureSession
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micStatus: SourceStatus = .off
    @Published private(set) var systemStatus: SourceStatus = .off
    @Published private(set) var droppedBuffers = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var currentRecordingID: UUID?
    private(set) var processingTask: Task<Void, Never>?

    let store: RecordingStore, pipeline: ProcessingPipeline, settings: AppSettings
    private let factory: Factory
    private let permissionCheck: () async -> String?
    private let mixer: ([URL], URL) async throws -> Void
    private var session: CaptureSession?
    private var currentID: UUID?
    private var startedAt: Date?
    private var timer: Timer?

    init(store: RecordingStore, pipeline: ProcessingPipeline, settings: AppSettings,
         factory: @escaping Factory = { try Recorder(sys: $0, mic: $1) },
         permissionCheck: @escaping () async -> String? = Permissions.ensure,
         mixer: @escaping ([URL], URL) async throws -> Void = mixAudio) {
        self.store = store; self.pipeline = pipeline; self.settings = settings
        self.factory = factory; self.permissionCheck = permissionCheck; self.mixer = mixer
    }

    func start(meeting: MeetingLink? = nil) async {
        guard state.canStart else { return }
        state = .starting
        if let problem = await permissionCheck() { state = .failed(problem); return }
        var created: UUID?
        do {
            let m = try store.create(language: settings.language, meeting: meeting)
            created = m.id
            let s = try factory(store.url(m.id, .system), store.url(m.id, .mic))
            s.onError = { [weak self] e in Task { @MainActor in await self?.streamFailed(e) } }
            try await s.start()
            session = s; currentID = m.id; currentRecordingID = m.id; startedAt = Date(); elapsed = 0; droppedBuffers = 0
            micStatus = .waiting; systemStatus = .waiting
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            if let id = created { store.discardIfEmpty(id) }
            state = .failed("Could not start recording: \(error.localizedDescription). Grant Screen & System Audio Recording and Microphone permission to Call Recorder in System Settings → Privacy & Security, then try again.")
        }
    }

    func stop(process: Bool = true) async {
        guard state == .recording else { return }
        await finish(note: nil, process: process)
    }

    private func streamFailed(_ e: Error) async {
        guard state == .recording else { return }
        await finish(note: "Capture stopped unexpectedly: \(e.localizedDescription). Audio recorded so far was saved.", process: true)
    }

    private func tick() {
        guard let s = session, let t = startedAt else { return }
        elapsed = Date().timeIntervalSince(t)
        droppedBuffers = s.droppedBuffers
        level = max(s.level, level * 0.7)   // fast attack, smooth decay
        micStatus = s.micActive ? .active : (elapsed > 5 ? .silent : .waiting)
        systemStatus = s.systemActive ? .active : (elapsed > 5 ? .silent : .waiting)
    }

    private func finish(note: String?, process: Bool) async {
        guard let s = session, let id = currentID else { return }
        state = .stopping
        timer?.invalidate(); timer = nil
        let wall = Date().timeIntervalSince(startedAt ?? Date())
        await s.stop()
        session = nil; currentID = nil; currentRecordingID = nil; level = 0
        micStatus = .off; systemStatus = .off
        state = .processing
        let dropped = s.droppedBuffers
        var notes = [note].compactMap { $0 }
        if dropped > 0 { notes.append("\(dropped) audio buffers were dropped; some audio may be missing.") }

        let sys = store.url(id, .system), mic = store.url(id, .mic), out = store.url(id, .audio)
        let raw = [sys, mic].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !raw.isEmpty else {
            store.update(id) { $0.phase = .finished; $0.needsRecovery = true; $0.note = (notes + ["No audio was captured."]).joined(separator: " ") }
            state = .failed("No audio was captured. Check microphone and Screen & System Audio Recording permissions.")
            return
        }
        var needsRecovery = false
        do { try await mixer(raw, out) }
        catch {
            // Keep the raw tracks (never deleted); copy one so playback still works.
            if !FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.copyItem(at: raw[0], to: out) }
            needsRecovery = !FileManager.default.fileExists(atPath: out.path)
            notes.append("Mixing failed (\(error.localizedDescription)); the separate tracks were kept.")
        }
        let dur = await audioDuration(out) ?? wall
        store.update(id) {
            $0.phase = .finished; $0.duration = dur; $0.droppedBuffers = dropped
            $0.needsRecovery = needsRecovery; $0.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        }
        droppedBuffers = dropped
        state = .completed(id)
        if process { processingTask = Task { await pipeline.process(id) } }
    }

    /// Call on quit: finalizes an active recording (no transcription) and waits for a mix in progress.
    func prepareForQuit() async {
        if state == .recording { await stop(process: false) }
        while state == .stopping || state == .processing || state == .starting { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Repairs recordings left unfinished by a crash/force-quit: re-mixes playable tracks. Never deletes anything.
    func recoverInterrupted() async {
        for id in store.markInterrupted() {
            var playable: [URL] = []
            for f in [RecFile.system, .mic] where await audioIsPlayable(store.url(id, f)) { playable.append(store.url(id, f)) }
            if await audioIsPlayable(store.url(id, .audio)) {
                // already mixed
            } else if !playable.isEmpty {
                do { try await mixer(playable, store.url(id, .audio)) } catch { continue }
            } else { continue }   // stays flagged "Needs recovery"; files untouched
            let dur = await audioDuration(store.url(id, .audio)) ?? 0
            store.update(id) { $0.needsRecovery = false; $0.duration = dur }
            await pipeline.process(id)
        }
    }
}
