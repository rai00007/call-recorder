import XCTest
@testable import CallRecorderCore

@MainActor
final class StoreTests: XCTestCase {
    func testSaveLoadAndRestart() throws {
        let e = Env()
        var m = try e.store.create(title: "Weekly", createdAt: Date(timeIntervalSince1970: 1_700_000_000))   // ISO8601 keeps whole seconds
        m.duration = 12; m.actionItems = [ActionItem(text: "x")]
        try e.store.save(m)
        let again = RecordingStore(root: e.store.root); again.load()   // simulated app restart
        XCTAssertEqual(again.recordings, [m])
    }

    func testSortedNewestFirstAndSearch() throws {
        let e = Env()
        let a = try e.store.create(title: "Old", createdAt: Date(timeIntervalSince1970: 1000))
        let b = try e.store.create(title: "New", createdAt: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(e.store.recordings.map(\.id), [b.id, a.id])
        try e.store.write(Fixtures.transcript, a.id, .transcript)
        XCTAssertEqual(e.store.search("checklist").map(\.id), [a.id])
        XCTAssertEqual(e.store.search("new").map(\.id), [b.id])
        XCTAssertEqual(e.store.search("").count, 2)
    }

    func testRenameAndDelete() throws {
        let e = Env()
        let m = try e.store.create(title: "A")
        e.store.rename(m.id, to: "  Renamed ")
        XCTAssertEqual(e.store.meta(m.id)?.title, "Renamed")
        e.store.rename(m.id, to: "   ")
        XCTAssertEqual(e.store.meta(m.id)?.title, "Renamed")
        try e.store.delete(m.id)
        XCTAssertTrue(e.store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.store.folder(m.id).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: e.trashDir.path).count, 1)   // trashed, not erased
    }

    func testCorruptMetadataIsSkippedNotDeleted() throws {
        let e = Env()
        let m = try e.store.create(title: "A")
        try "not json".write(to: e.store.url(m.id, .meta), atomically: true, encoding: .utf8)
        e.store.load()
        XCTAssertTrue(e.store.recordings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.store.url(m.id, .meta).path))
    }

    func testEditedTranscriptKeepsOriginal() throws {
        let e = Env()
        let m = try e.store.create()
        try e.store.write("orig", m.id, .transcript)
        try e.store.write("edited", m.id, .edited)
        XCTAssertEqual(e.store.transcriptText(m.id), "edited")
        XCTAssertEqual(e.store.read(m.id, .transcript), "orig")
    }

    func testLegacyImportIsNonDestructiveAndIdempotent() async throws {
        let e = Env()
        let legacy = Fixtures.tempDir()
        let base = "call_2026-11-12_14-30-00"
        try Fixtures.makeAudio(legacy.appendingPathComponent(base + ".m4a"), seconds: 2)
        try Fixtures.transcript.write(to: legacy.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
        try Fixtures.minutes.write(to: legacy.appendingPathComponent(base + ".minutes.md"), atomically: true, encoding: .utf8)
        let n = await e.store.importLegacy(from: legacy)
        XCTAssertEqual(n, 1)
        let m = try XCTUnwrap(e.store.recordings.first)
        XCTAssertEqual(m.transcript, .done); XCTAssertEqual(m.summary, .done)
        XCTAssertGreaterThan(m.duration, 1)
        XCTAssertTrue(e.store.exists(m.id, .audio))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: legacy.path).count, 3)   // originals still there
        let again = await e.store.importLegacy(from: legacy)
        XCTAssertEqual(again, 0)
        XCTAssertEqual(e.store.recordings.count, 1)
    }

    func testRawTrackCleanupRules() async throws {
        let e = Env()
        func make(_ title: String, age: Double, transcribed: Bool, audio: Bool = true, recovery: Bool = false) throws -> UUID {
            var m = try e.store.create(title: title, createdAt: Date().addingTimeInterval(-age * 86400))
            m.phase = .finished; m.needsRecovery = recovery; m.transcript = transcribed ? .done : .idle
            try e.store.save(m)
            try Fixtures.makeAudio(e.store.url(m.id, .system)); try Fixtures.makeAudio(e.store.url(m.id, .mic))
            if audio { try Fixtures.makeAudio(e.store.url(m.id, .audio)) }
            return m.id
        }
        let old = try make("old", age: 40, transcribed: true)
        let new = try make("new", age: 1, transcribed: false)
        let rec = try make("recovery", age: 50, transcribed: true, recovery: true)
        let noAudio = try make("noaudio", age: 50, transcribed: true, audio: false)
        XCTAssertEqual(Set(e.store.rawCleanupCandidates(.olderThan(days: 30, now: Date()))), [old, noAudio])
        XCTAssertEqual(Set(e.store.rawCleanupCandidates(.transcribed)), [old, noAudio])
        XCTAssertEqual(Set(e.store.rawCleanupCandidates(.selected([new, rec]))), [new])
        XCTAssertEqual(e.store.rawCleanupCandidates(.all).count, 3)
        // nothing has been removed so far
        XCTAssertTrue(e.store.exists(old, .system))
        let r = await e.store.deleteRawTracks([old, noAudio, rec])
        XCTAssertEqual(r.count, 1); XCTAssertGreaterThan(r.bytes, 0)
        XCTAssertFalse(e.store.exists(old, .system)); XCTAssertFalse(e.store.exists(old, .mic))
        XCTAssertTrue(e.store.exists(old, .audio))
        XCTAssertTrue(e.store.exists(noAudio, .system))   // refused: no mixed audio
        XCTAssertTrue(e.store.exists(rec, .mic))          // refused: needs recovery
        XCTAssertEqual(e.store.meta(old)?.rawTracksRemoved, true)
    }

    func testInterruptedRecordingIsFlaggedNotDeleted() throws {
        let e = Env()
        let m = try e.store.create()   // phase == .recording (never finished)
        try Fixtures.makeAudio(e.store.url(m.id, .mic))
        e.store.update(m.id) { $0.transcript = .running }
        XCTAssertEqual(e.store.markInterrupted(), [m.id])
        XCTAssertEqual(e.store.meta(m.id)?.needsRecovery, true)
        XCTAssertTrue(e.store.meta(m.id)!.transcript.isFailed)
        XCTAssertTrue(e.store.exists(m.id, .mic))
    }

    func testSettingsPersist() {
        let e = Env()
        e.settings.language = "de-DE"; e.settings.ollamaModel = "llama3"; e.settings.autoSummarize = false
        let s2 = AppSettings(defaults: e.defaults)
        XCTAssertEqual(s2.language, "de-DE"); XCTAssertEqual(s2.ollamaModel, "llama3"); XCTAssertFalse(s2.autoSummarize)
        XCTAssertEqual(AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!).language, "en-US")
    }
}
