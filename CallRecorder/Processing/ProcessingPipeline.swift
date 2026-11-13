import Foundation

/// Transcription and summarization are separate, independently retryable steps.
/// Failures are recorded in metadata; audio and existing transcripts are never touched on failure.
@MainActor
final class ProcessingPipeline {
    let store: RecordingStore
    let settings: AppSettings
    var transcriber: Transcriber
    var http: HTTPClient

    init(store: RecordingStore, settings: AppSettings, transcriber: Transcriber = AppleSpeechTranscriber(), http: HTTPClient = URLSession.shared) {
        self.store = store; self.settings = settings; self.transcriber = transcriber; self.http = http
    }

    func process(_ id: UUID) async {
        await transcribe(id)
        if settings.autoSummarize, store.meta(id)?.transcript == .done { await summarize(id) }
    }

    func transcribe(_ id: UUID) async {
        guard store.meta(id) != nil else { return }
        var tracks: [(url: URL, who: String)] = []
        if store.exists(id, .system) { tracks.append((store.url(id, .system), "Others")) }
        if store.exists(id, .mic) { tracks.append((store.url(id, .mic), "Me")) }
        if tracks.isEmpty, store.exists(id, .audio) { tracks = [(store.url(id, .audio), "Speaker")] }   // raw tracks removed: no Me/Others
        guard !tracks.isEmpty else {
            store.update(id) { $0.transcript = .failed("No audio files found for this recording.") }
            return
        }
        let lang = settings.language
        store.update(id) { $0.transcript = .running; $0.language = lang }
        do {
            let text = try await transcriber.transcribe(tracks: tracks, language: lang)
            try store.write(text, id, .transcript)
            store.update(id) { $0.transcript = .done }
        } catch {
            store.update(id) { $0.transcript = .failed(error.localizedDescription) }
        }
    }

    /// `regenerateActions` replaces user-edited action items with freshly parsed ones.
    func summarize(_ id: UUID, regenerateActions: Bool = false) async {
        guard let m = store.meta(id) else { return }
        let transcript = store.transcriptText(id)
        guard !transcript.isEmpty else {
            store.update(id) { $0.summary = .failed("No transcript to summarize. Transcribe first.") }
            return
        }
        store.update(id) { $0.summary = .running }
        let svc = OllamaService(baseURL: settings.ollamaBaseURL, model: settings.ollamaModel, http: http)
        do {
            let md = try await svc.minutes(transcript: transcript, title: m.title)
            try store.write(md, id, .minutes)
            let items = ActionItemParser.attachSources(ActionItemParser.parse(md), transcript: TranscriptFormat.parse(transcript))
            store.update(id) {
                $0.summary = .done
                if regenerateActions || !$0.actionItemsEdited { $0.actionItems = items; $0.actionItemsEdited = false }
            }
        } catch {
            store.update(id) { $0.summary = .failed(error.localizedDescription) }
        }
    }
}
