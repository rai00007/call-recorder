import XCTest
@testable import CallRecorderCore

@MainActor
final class RecordingManagerTests: XCTestCase {
    private func make(session: FakeSession = FakeSession(), permission: String? = nil, mixer: (([URL], URL) async throws -> Void)? = nil,
                      transcript: Result<String, Error> = .success(Fixtures.transcript)) -> (Env, RecordingManager, FakeSession, FakeTranscriber, ProcessingPipeline) {
        let e = Env()
        e.settings.autoSummarize = false
        let ft = FakeTranscriber(transcript)
        let pipe = ProcessingPipeline(store: e.store, settings: e.settings, transcriber: ft, http: FakeHTTP { _ in (Data(), 500) })
        var created = 0
        let mgr = RecordingManager(store: e.store, pipeline: pipe, settings: e.settings,
                                   factory: { sys, mic in created += 1; session.writeFiles = [sys, mic]; return session },
                                   permissionCheck: { permission },
                                   mixer: mixer ?? { inputs, out in try await mixAudio(inputs, to: out) })
        return (e, mgr, session, ft, pipe)
    }

    func testStartStopTransitionsAndFinalization() async throws {
        let (e, m, _, ft, _) = make()
        XCTAssertEqual(m.state, .idle)
        await m.start()
        XCTAssertEqual(m.state, .recording)
        await m.stop()
        guard case .completed(let id) = m.state else { return XCTFail("state \(m.state)") }
        await m.processingTask?.value
        let meta = try XCTUnwrap(e.store.meta(id))
        XCTAssertEqual(meta.phase, .finished)
        XCTAssertTrue(e.store.exists(id, .audio) && e.store.exists(id, .mic) && e.store.exists(id, .system))   // raw tracks kept
        XCTAssertGreaterThan(meta.duration, 0)
        XCTAssertEqual(meta.transcript, .done); XCTAssertEqual(ft.calls, 1)
    }

    func testRepeatedStartAndStopAreIgnored() async throws {
        let (e, m, _, _, _) = make()
        async let a: () = m.start(); async let b: () = m.start()
        _ = await (a, b)
        XCTAssertEqual(e.store.recordings.count, 1)
        await m.start()
        XCTAssertEqual(e.store.recordings.count, 1)
        async let s1: () = m.stop(); async let s2: () = m.stop()
        _ = await (s1, s2)
        await m.stop()
        await m.processingTask?.value
        XCTAssertEqual(e.store.recordings.count, 1)
    }

    func testStopWhileIdleDoesNothing() async {
        let (_, m, _, _, _) = make()
        await m.stop()
        XCTAssertEqual(m.state, .idle)
    }

    func testMissingPermissionBlocksStartAndCreatesNothing() async {
        let (e, m, _, _, _) = make(permission: "Microphone access is denied.")
        await m.start()
        XCTAssertEqual(m.state, .failed("Microphone access is denied."))
        XCTAssertTrue(e.store.recordings.isEmpty)
        XCTAssertTrue(m.state.canStart)
    }

    func testStartFailureCleansUpEmptyFolderOnly() async {
        let s = FakeSession(); s.failStart = URLError(.cannotConnectToHost)
        let (e, m, _, _, _) = make(session: s)
        await m.start()
        guard case .failed = m.state else { return XCTFail() }
        XCTAssertTrue(e.store.recordings.isEmpty)
    }

    func testStreamInterruptionSavesAudioAndFlagsNote() async throws {
        let (e, m, s, _, _) = make()
        await m.start()
        s.onError?(URLError(.networkConnectionLost))
        for _ in 0..<100 { if case .completed = m.state { break }; try await Task.sleep(for: .milliseconds(50)) }
        guard case .completed(let id) = m.state else { return XCTFail("state \(m.state)") }
        await m.processingTask?.value
        XCTAssertTrue(e.store.meta(id)!.note!.contains("Capture stopped unexpectedly"))
        XCTAssertTrue(e.store.exists(id, .audio))
    }

    func testDroppedBuffersRecorded() async throws {
        let s = FakeSession(); s.droppedBuffers = 7
        let (e, m, _, _, _) = make(session: s)
        await m.start(); await m.stop()
        guard case .completed(let id) = m.state else { return XCTFail() }
        XCTAssertEqual(e.store.meta(id)?.droppedBuffers, 7)
        XCTAssertTrue(e.store.meta(id)!.note!.contains("dropped"))
    }

    func testMixFailureKeepsAllAudio() async throws {
        let (e, m, _, _, _) = make(mixer: { _, _ in throw URLError(.cannotWriteToFile) })
        await m.start(); await m.stop()
        guard case .completed(let id) = m.state else { return XCTFail("state \(m.state)") }
        await m.processingTask?.value
        XCTAssertTrue(e.store.exists(id, .system) && e.store.exists(id, .mic))
        XCTAssertTrue(e.store.exists(id, .audio))   // fallback copy so playback works
        XCTAssertTrue(e.store.meta(id)!.note!.contains("Mixing failed"))
    }

    func testNoAudioCapturedIsReportedAndRecordKept() async throws {
        let s = FakeSession()
        let (e, m, _, _, _) = make(session: s)
        await m.start()
        s.writeFiles = []   // nothing written
        await m.stop()
        guard case .failed = m.state else { return XCTFail("state \(m.state)") }
        XCTAssertEqual(e.store.recordings.count, 1)
        XCTAssertTrue(e.store.recordings[0].needsRecovery)
    }

    func testTranscriptionFailureNeverDropsAudio() async throws {
        let (e, m, _, _, _) = make(transcript: .failure(TranscriptionError(errorDescription: "boom")))
        await m.start(); await m.stop()
        guard case .completed(let id) = m.state else { return XCTFail() }
        await m.processingTask?.value
        XCTAssertTrue(e.store.meta(id)!.transcript.isFailed)
        XCTAssertTrue(e.store.exists(id, .audio) && e.store.exists(id, .mic))
    }

    func testQuitDuringRecordingFinalizesWithoutProcessing() async throws {
        let (e, m, _, ft, _) = make()
        await m.start()
        await m.prepareForQuit()
        guard case .completed(let id) = m.state else { return XCTFail("state \(m.state)") }
        XCTAssertTrue(e.store.exists(id, .audio))
        XCTAssertEqual(ft.calls, 0)
    }

    func testRecoveryRemixesInterruptedRecording() async throws {
        let (e, m, _, ft, _) = make()
        let r = try e.store.create(title: "crashed")   // phase stays .recording
        try Fixtures.makeAudio(e.store.url(r.id, .mic))
        try Data("garbage".utf8).write(to: e.store.url(r.id, .system))   // unreadable partial file
        await m.recoverInterrupted()
        let meta = try XCTUnwrap(e.store.meta(r.id))
        XCTAssertFalse(meta.needsRecovery)
        XCTAssertTrue(e.store.exists(r.id, .audio))
        XCTAssertTrue(e.store.exists(r.id, .system))   // never deleted
        XCTAssertEqual(ft.calls, 1)
    }

    func testRecoveryWithNothingPlayableKeepsFilesFlagged() async throws {
        let (e, m, _, _, _) = make()
        let r = try e.store.create()
        try Data("garbage".utf8).write(to: e.store.url(r.id, .mic))
        await m.recoverInterrupted()
        XCTAssertTrue(e.store.meta(r.id)!.needsRecovery)
        XCTAssertTrue(e.store.exists(r.id, .mic))
    }
}

@MainActor
final class MiscTests: XCTestCase {
    func testPlayerControls() async throws {
        let url = Fixtures.tempDir().appendingPathComponent("a.m4a")
        try Fixtures.makeAudio(url, seconds: 2)
        let p = PlayerModel(url: url)
        for _ in 0..<50 where p.duration == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(p.duration, 1.5)
        p.play(); XCTAssertTrue(p.isPlaying)
        p.pause(); XCTAssertFalse(p.isPlaying)
        p.setRate(1.5); XCTAssertEqual(p.rate, 1.5)
        p.seek(to: 1); XCTAssertEqual(p.currentTime, 1, accuracy: 0.01)
        p.seek(to: 999); XCTAssertEqual(p.currentTime, p.duration, accuracy: 0.01)
    }

    func testExportsProduceUsableFiles() throws {
        let e = Env()
        var m = try e.store.create(title: "Weekly")
        try e.store.write(Fixtures.transcript, m.id, .transcript)
        try e.store.write("edited line", m.id, .edited)
        try e.store.write(Fixtures.minutes, m.id, .minutes)
        m.actionItems = [ActionItem(text: "Send checklist", owner: "Me", due: "Friday", sourceRef: "00:20", done: true), ActionItem(text: "Plain")]
        try e.store.save(m)
        let out = Fixtures.tempDir()
        try Exporter.write(Exporter.transcript(e.store, m.id), to: out.appendingPathComponent("t.txt"))
        try Exporter.write(Exporter.summary(e.store, m.id), to: out.appendingPathComponent("s.md"))
        try Exporter.write(Exporter.actions(m), to: out.appendingPathComponent("a.md"))
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("t.txt")), "edited line")
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("s.md")).contains("## Summary"))
        let a = try String(contentsOf: out.appendingPathComponent("a.md"))
        XCTAssertTrue(a.contains("- [x] Send checklist (owner: Me, due: Friday, transcript 00:20)"))
        XCTAssertTrue(a.contains("- [ ] Plain\n"))
        XCTAssertFalse(a.contains("owner: nil"))
    }

    func testDetailFilesMapToTabs() throws {
        let e = Env()
        let m = try e.store.create()
        try e.store.write("T", m.id, .transcript); try e.store.write("M", m.id, .minutes)
        XCTAssertEqual(e.store.transcriptText(m.id), "T"); XCTAssertEqual(e.store.read(m.id, .minutes), "M")
        XCTAssertTrue(e.store.url(m.id, .audio).path.hasSuffix("\(m.id.uuidString)/audio.m4a"))
    }
}
