import Foundation
import AVFoundation

enum RecFile: String {
    case audio = "audio.m4a", system = "system.m4a", mic = "mic.m4a"
    case transcript = "transcript.txt", edited = "transcript.edited.txt"
    case minutes = "minutes.md", meta = "metadata.json"
}

enum RawCleanupFilter {
    case selected(Set<UUID>), olderThan(days: Int, now: Date), transcribed, all
}

/// Library on disk: <root>/<uuid>/{audio.m4a, system.m4a, mic.m4a, transcript.txt, transcript.edited.txt, minutes.md, metadata.json}
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [RecordingMetadata] = []
    private(set) var root: URL
    private let trash: (URL) throws -> Void
    private let fm = FileManager.default

    init(root: URL, trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.root = root; self.trash = trash
    }

    func setRoot(_ url: URL) { root = url; load() }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    func url(_ id: UUID, _ f: RecFile) -> URL { folder(id).appendingPathComponent(f.rawValue) }
    func exists(_ id: UUID, _ f: RecFile) -> Bool { fm.fileExists(atPath: url(id, f).path) }
    func meta(_ id: UUID) -> RecordingMetadata? { recordings.first { $0.id == id } }
    func size(_ id: UUID, _ f: RecFile) -> Int64 {
        ((try? fm.attributesOfItem(atPath: url(id, f).path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    /// Scans the root. Folders with unreadable metadata are skipped, never deleted.
    func load() {
        let dec = Self.coder().1
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        recordings = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(RecFile.meta.rawValue)) else { return nil }
            return try? dec.decode(RecordingMetadata.self, from: data)
        }
        sort()
    }

    private func sort() { recordings.sort { $0.createdAt > $1.createdAt } }

    static func defaultTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return "Call " + f.string(from: d)
    }

    @discardableResult
    func create(title: String? = nil, language: String? = nil, createdAt: Date = Date(), legacySource: String? = nil) throws -> RecordingMetadata {
        var m = RecordingMetadata(id: UUID(), title: title ?? Self.defaultTitle(createdAt), createdAt: createdAt)
        m.language = language; m.legacySource = legacySource
        try fm.createDirectory(at: folder(m.id), withIntermediateDirectories: true)
        try save(m)
        return m
    }

    func save(_ m: RecordingMetadata) throws {
        try Self.coder().0.encode(m).write(to: url(m.id, .meta), options: .atomic)
        if let i = recordings.firstIndex(where: { $0.id == m.id }) { recordings[i] = m } else { recordings.append(m) }
        sort()
    }

    func update(_ id: UUID, _ change: (inout RecordingMetadata) -> Void) {
        guard var m = meta(id) else { return }
        change(&m)
        do { try save(m) } catch { FileHandle.standardError.write(Data("metadata save failed: \(error)\n".utf8)) }
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { update(id) { $0.title = t } }
    }

    /// Moves the whole recording folder (audio + generated data) to the Trash.
    func delete(_ id: UUID) throws {
        try trash(folder(id))
        recordings.removeAll { $0.id == id }
    }

    /// Removes a just-created folder only if nothing was recorded into it.
    func discardIfEmpty(_ id: UUID) {
        let files = ((try? fm.contentsOfDirectory(atPath: folder(id).path)) ?? []).filter { $0 != RecFile.meta.rawValue }
        guard files.isEmpty else { return }
        try? fm.removeItem(at: folder(id))
        recordings.removeAll { $0.id == id }
    }

    // MARK: text
    func read(_ id: UUID, _ f: RecFile) -> String { (try? String(contentsOf: url(id, f), encoding: .utf8)) ?? "" }
    func write(_ text: String, _ id: UUID, _ f: RecFile) throws { try text.write(to: url(id, f), atomically: true, encoding: .utf8) }
    /// The transcript users see: their edited copy if present, else the original.
    func transcriptText(_ id: UUID) -> String { exists(id, .edited) ? read(id, .edited) : read(id, .transcript) }

    func search(_ query: String) -> [RecordingMetadata] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return recordings }
        return recordings.filter { $0.title.localizedCaseInsensitiveContains(q) || transcriptText($0.id).localizedCaseInsensitiveContains(q) }
    }

    // MARK: import / recovery
    /// Non-destructive: COPIES `call_*.m4a/.txt/.minutes.md` from the old recordings folder. Originals are untouched.
    @discardableResult
    func importLegacy(from dir: URL) async -> Int {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let known = Set(recordings.compactMap(\.legacySource))
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var count = 0
        for f in files where f.lastPathComponent.hasPrefix("call_") && f.pathExtension == "m4a" && !f.lastPathComponent.contains(".tmp.") {
            let name = f.lastPathComponent
            guard !known.contains(name) else { continue }
            let base = f.deletingPathExtension().lastPathComponent
            let stamp = String(base.dropFirst(5))
            let date = parse.date(from: stamp)
                ?? (try? f.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            guard let m = try? create(createdAt: date, legacySource: name) else { continue }
            let pairs: [(String, RecFile)] = [(name, .audio), (base + ".txt", .transcript), (base + ".minutes.md", .minutes),
                                              (base + ".system.tmp.m4a", .system), (base + ".mic.tmp.m4a", .mic)]
            var ok = true
            for (src, dst) in pairs where fm.fileExists(atPath: dir.appendingPathComponent(src).path) {
                do { try fm.copyItem(at: dir.appendingPathComponent(src), to: url(m.id, dst)) } catch { ok = false }
            }
            guard ok else { try? fm.removeItem(at: folder(m.id)); recordings.removeAll { $0.id == m.id }; continue }
            let dur = (try? await AVURLAsset(url: url(m.id, .audio)).load(.duration).seconds) ?? 0
            update(m.id) {
                $0.phase = .finished; $0.duration = dur.isFinite ? dur : 0
                $0.transcript = exists(m.id, .transcript) ? .done : .idle
                $0.summary = exists(m.id, .minutes) ? .done : .idle
            }
            count += 1
        }
        return count
    }

    /// Marks recordings left in the `recording` phase (crash/force quit) and steps left `running`. Returns ids to repair.
    func markInterrupted() -> [UUID] {
        var ids: [UUID] = []
        for m in recordings {
            if m.phase == .recording {
                update(m.id) { $0.phase = .finished; $0.needsRecovery = true; $0.note = "Recording was interrupted; audio recovered where possible." }
                ids.append(m.id)
            }
            if m.transcript == .running { update(m.id) { $0.transcript = .failed("Interrupted — retry") } }
            if m.summary == .running { update(m.id) { $0.summary = .failed("Interrupted — retry") } }
        }
        return ids
    }

    // MARK: raw-track cleanup (user initiated only)
    func rawBytes(_ id: UUID) -> Int64 { size(id, .system) + size(id, .mic) }

    func rawCleanupCandidates(_ filter: RawCleanupFilter) -> [UUID] {
        recordings.filter { m in
            guard !m.needsRecovery, m.phase == .finished, exists(m.id, .system) || exists(m.id, .mic) else { return false }
            switch filter {
            case .selected(let ids): return ids.contains(m.id)
            case .olderThan(let days, let now): return m.createdAt < now.addingTimeInterval(-Double(days) * 86400)
            case .transcribed: return m.transcript == .done
            case .all: return true
            }
        }.map(\.id)
    }

    /// Trashes only system.m4a / mic.m4a, and only if the mixed audio.m4a is playable.
    @discardableResult
    func deleteRawTracks(_ ids: [UUID]) async -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        for id in ids {
            guard let m = meta(id), !m.needsRecovery, exists(id, .audio),
                  (try? await AVURLAsset(url: url(id, .audio)).load(.isPlayable)) == true else { continue }
            var removed = false
            for f in [RecFile.system, .mic] where exists(id, f) {
                let s = size(id, f)
                if (try? trash(url(id, f))) != nil { bytes += s; removed = true }
            }
            if removed { update(id) { $0.rawTracksRemoved = true }; count += 1 }
        }
        return (count, bytes)
    }
}
