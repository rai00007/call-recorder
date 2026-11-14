import Foundation

/// Debounced, atomic writer for handwritten notes. Notes live in their own file and are never touched by
/// transcription, summarization or metadata updates. Writes happen only after an explicit edit, so loading
/// an empty or missing file can never overwrite saved notes.
@MainActor
final class NotesAutosaver: ObservableObject {
    @Published private(set) var isSaved = true
    private static let live = NSHashTable<NotesAutosaver>.weakObjects()
    private let url: URL
    private let debounce: Duration
    private var pending: String?
    private var task: Task<Void, Never>?

    init(url: URL, debounce: Duration = .milliseconds(800)) {
        self.url = url; self.debounce = debounce
        Self.live.add(self)
    }

    func load() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func edit(_ text: String) {
        pending = text; isSaved = false
        task?.cancel()
        task = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            if !Task.isCancelled { flush() }
        }
    }

    func flush() {
        task?.cancel(); task = nil
        guard let text = pending else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            pending = nil; isSaved = true
        } catch { FileHandle.standardError.write(Data("notes save failed: \(error)\n".utf8)) }
    }

    /// Call on quit / app deactivation so nothing typed in the last moments is lost.
    static func flushAll() { for s in live.allObjects { s.flush() } }
}
