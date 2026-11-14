import XCTest
@testable import CallRecorderCore

@MainActor
final class MeetingStoreTests: XCTestCase {
    func testEnsureIsIdempotentAndSnapshotNeverOverwritten() throws {
        let e = Env()
        let ms = MeetingStore(recordingsRoot: e.dir.appendingPathComponent("lib"))
        let ev = makeEvent("a", start: 600, title: "Original")
        let first = ms.ensure(ev)
        let edited = makeEvent("a", start: 600, title: "Edited later")
        XCTAssertEqual(ms.ensure(edited).snapshot.title, "Original")
        XCTAssertEqual(ms.meetings.count, 1); XCTAssertEqual(first.id, ev.id)
        let reload = MeetingStore(recordingsRoot: e.dir.appendingPathComponent("lib")); reload.load()
        XCTAssertEqual(reload.meeting(ev.id)?.snapshot.title, "Original")
        XCTAssertEqual(reload.meeting(ev.id)?.snapshot.invitees.first?.name, "Ana")
    }

    func testMeetingsFolderIsNotLoadedAsRecording() throws {
        let e = Env()
        let ms = MeetingStore(recordingsRoot: e.store.root)
        ms.ensure(makeEvent("a", start: 600))
        try NotesAutosaverHelper.write("n", ms.notesURL(makeEvent("a", start: 600).id))
        let r = try e.store.create()
        e.store.load()
        XCTAssertEqual(e.store.recordings.map(\.id), [r.id])
    }

    func testRecordingsLinkToMeetingAndDefaultTitle() throws {
        let e = Env()
        let ev = makeEvent("a", start: 600, title: "Design review")
        let a = try e.store.create(meeting: ev.link), b = try e.store.create(meeting: ev.link), solo = try e.store.create()
        XCTAssertEqual(a.title, "Design review")
        e.store.rename(a.id, to: "Renamed")
        XCTAssertEqual(e.store.meta(a.id)?.title, "Renamed")
        XCTAssertEqual(e.store.notesURL(a.id), e.store.notesURL(b.id))        // shared meeting notes
        XCTAssertNotEqual(e.store.notesURL(solo.id), e.store.notesURL(a.id))
        XCTAssertEqual(e.store.notesURL(solo.id), e.store.url(solo.id, .notes))
        e.store.load()
        XCTAssertEqual(e.store.meta(b.id)?.meeting?.snapshot.title, "Design review")
        XCTAssertEqual(e.store.meta(b.id)?.meeting?.snapshot.joinLink?.host, "meet.google.com")
    }

    func testLegacyMetadataWithoutMeetingStillDecodes() throws {
        let e = Env()
        let id = UUID(); let dir = e.store.folder(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"id":"\#(id.uuidString)","title":"Old","createdAt":"2025-01-01T10:00:00Z","duration":5,"phase":"finished","transcript":{"idle":{}},"summary":{"idle":{}},"needsRecovery":false,"rawTracksRemoved":false,"droppedBuffers":0,"actionItems":[],"actionItemsEdited":false}"#
        try json.write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        e.store.load()
        XCTAssertEqual(e.store.meta(id)?.title, "Old"); XCTAssertNil(e.store.meta(id)?.meeting)
    }
}

enum NotesAutosaverHelper {
    static func write(_ s: String, _ u: URL) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }
}

@MainActor
final class NotesTests: XCTestCase {
    func testDebounceFlushAndReload() async throws {
        let url = Fixtures.tempDir().appendingPathComponent("x/notes.md")
        let s = NotesAutosaver(url: url, debounce: .milliseconds(50))
        s.edit("hello")
        XCTAssertFalse(s.isSaved)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(s.isSaved)
        XCTAssertEqual(NotesAutosaver(url: url).load(), "hello")
        let s2 = NotesAutosaver(url: url, debounce: .seconds(30))
        s2.edit("typed just before quit"); NotesAutosaver.flushAll()
        XCTAssertEqual(s.load(), "typed just before quit")
    }

    func testLoadingNeverClobbersExistingNotes() throws {
        let url = Fixtures.tempDir().appendingPathComponent("notes.md")
        try "keep".write(to: url, atomically: true, encoding: .utf8)
        let s = NotesAutosaver(url: url); _ = s.load(); s.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
    }

    func testNotesEditableDuringRecordingAndSurviveTranscriptionFailureAndRegeneration() async throws {
        let e = Env(); e.settings.autoSummarize = false
        let ft = FakeTranscriber(.failure(NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "speech failed"])))
        let pipe = ProcessingPipeline(store: e.store, settings: e.settings, transcriber: ft, http: FakeHTTP { _ in (Data(), 500) })
        let session = FakeSession()
        let m = RecordingManager(store: e.store, pipeline: pipe, settings: e.settings,
                                 factory: { s, mic in session.writeFiles = [s, mic]; return session }, permissionCheck: { nil },
                                 mixer: { i, o in try await mixAudio(i, to: o) })
        let ev = makeEvent("a", start: 600, title: "Planning")
        await m.start(meeting: ev.link)
        XCTAssertEqual(m.state, .recording)
        let id = try XCTUnwrap(m.currentRecordingID)
        XCTAssertEqual(e.store.meta(id)?.title, "Planning")
        let saver = NotesAutosaver(url: e.store.notesURL(id), debounce: .milliseconds(10))
        saver.edit("during recording"); saver.flush()                          // editable while recording
        await m.stop()
        await m.processingTask?.value
        XCTAssertTrue(e.store.meta(id)?.transcript.isFailed ?? false)          // transcription failed
        XCTAssertEqual(saver.load(), "during recording")                       // notes intact
        await pipe.transcribe(id); await pipe.summarize(id)                    // retries/regeneration
        XCTAssertEqual(saver.load(), "during recording")
        XCTAssertFalse(e.store.exists(id, .minutes))                           // notes are not minutes
        e.store.load()
        XCTAssertEqual(NotesAutosaver(url: e.store.notesURL(id)).load(), "during recording")   // survives reload
    }

    func testMeetingNotesWithoutRecording() throws {
        let e = Env()
        let ms = MeetingStore(recordingsRoot: e.store.root)
        let ev = makeEvent("a", start: 600)
        ms.ensure(ev)
        let s = NotesAutosaver(url: ms.notesURL(ev.id)); s.edit("pre-meeting"); s.flush()
        let again = MeetingStore(recordingsRoot: e.store.root); again.load()
        XCTAssertEqual(NotesAutosaver(url: again.notesURL(ev.id)).load(), "pre-meeting")
    }
}

final class MarkdownBlocksTests: XCTestCase {
    func testParsesHeadingsBulletsChecks() {
        let b = MarkdownBlocks.parse("## Summary\nText here\n\n- point\n  - nested\n- [ ] todo\n- [x] done\n- [Me] owner item")
        XCTAssertEqual(b, [.heading(2, "Summary"), .paragraph("Text here"), .bullet("point", indent: 0), .bullet("nested", indent: 1),
                           .check(false, "todo"), .check(true, "done"), .bullet("[Me] owner item", indent: 0)])
    }
}
