import XCTest
@testable import CallRecorderCore

@MainActor
final class ProcessingTests: XCTestCase {
    private func ollama(models: [String] = ["qwen2.5:3b"], reply: String = "## Summary\nok\n## Action items\n- [Me] Do it (due: not stated)") -> FakeHTTP {
        FakeHTTP { req in
            if req.url!.path.hasSuffix("tags") { return (try JSONSerialization.data(withJSONObject: ["models": models.map { ["name": $0] }]), 200) }
            return (try JSONSerialization.data(withJSONObject: ["message": ["content": reply]]), 200)
        }
    }
    private func words(_ n: Int) -> String { (0..<n).map { _ in "word" }.joined(separator: " ") }

    private func setup(_ t: Result<String, Error>, http: HTTPClient) throws -> (Env, ProcessingPipeline, FakeTranscriber, UUID) {
        let e = Env()
        let ft = FakeTranscriber(t)
        let p = ProcessingPipeline(store: e.store, settings: e.settings, transcriber: ft, http: http)
        let m = try e.store.create(title: "T")
        try Fixtures.makeAudio(e.store.url(m.id, .audio)); try Fixtures.makeAudio(e.store.url(m.id, .mic)); try Fixtures.makeAudio(e.store.url(m.id, .system))
        return (e, p, ft, m.id)
    }

    func testSuccessfulTranscriptionUsesMeOthersTracks() async throws {
        let (e, p, ft, id) = try setup(.success(Fixtures.transcript), http: ollama())
        await p.transcribe(id)
        XCTAssertEqual(e.store.meta(id)?.transcript, .done)
        XCTAssertEqual(ft.lastTracks, ["Others", "Me"])
        XCTAssertEqual(e.store.read(id, .transcript), Fixtures.transcript)
    }

    func testFailedTranscriptionKeepsAudioAndRetrySucceeds() async throws {
        let (e, p, ft, id) = try setup(.failure(TranscriptionError(errorDescription: "No speech was detected")), http: ollama())
        await p.transcribe(id)
        XCTAssertTrue(e.store.meta(id)!.transcript.isFailed)
        XCTAssertTrue(e.store.exists(id, .audio) && e.store.exists(id, .mic) && e.store.exists(id, .system))
        ft.result = .success(Fixtures.transcript)
        await p.transcribe(id)
        XCTAssertEqual(e.store.meta(id)?.transcript, .done)
    }

    func testTranscribeFallsBackToMixedAudioWhenRawRemoved() async throws {
        let (e, p, ft, id) = try setup(.success(Fixtures.transcript), http: ollama())
        try FileManager.default.removeItem(at: e.store.url(id, .mic)); try FileManager.default.removeItem(at: e.store.url(id, .system))
        await p.transcribe(id)
        XCTAssertEqual(ft.lastTracks, ["Speaker"])
    }

    func testOllamaUnavailableLeavesTranscriptAndRetryWorksWithoutRetranscribing() async throws {
        var up = false
        let http = FakeHTTP { req in
            guard up else { throw URLError(.cannotConnectToHost) }
            return try self.ollama().handler(req)
        }
        let (e, p, ft, id) = try setup(.success(words(200).replacingOccurrences(of: "word", with: "[00:01] Me: hello")), http: http)
        await p.process(id)
        XCTAssertEqual(e.store.meta(id)?.transcript, .done)
        guard case .failed(let msg) = e.store.meta(id)!.summary else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("Ollama isn't running"))
        XCTAssertEqual(ft.calls, 1)
        up = true
        await p.summarize(id)
        XCTAssertEqual(e.store.meta(id)?.summary, .done)
        XCTAssertEqual(ft.calls, 1)   // not retranscribed
        XCTAssertTrue(e.store.read(id, .minutes).contains("## Summary"))
    }

    func testMissingModelAndAutoSummarizeOff() async throws {
        let (e, p, _, id) = try setup(.success(words(200)), http: ollama(models: ["other"]))
        await p.process(id)
        XCTAssertTrue(e.store.meta(id)!.summary.isFailed)
        let (e2, p2, _, id2) = try setup(.success(words(200)), http: ollama())
        e2.settings.autoSummarize = false
        await p2.process(id2)
        XCTAssertEqual(e2.store.meta(id2)?.summary, .idle)
    }

    func testShortTranscriptNotSentToModel() async throws {
        var chatCalls = 0
        let http = FakeHTTP { req in chatCalls += req.url!.path.hasSuffix("chat") ? 1 : 0; return (Data(), 500) }
        let (e, p, _, id) = try setup(.success(Fixtures.transcript), http: http)
        await p.process(id)
        XCTAssertEqual(chatCalls, 0)
        XCTAssertEqual(e.store.meta(id)?.summary, .done)
        XCTAssertTrue(e.store.read(id, .minutes).contains("too short"))
    }

    func testLongTranscriptIsChunked() async throws {
        let line = "[00:01] Me: " + words(100)
        let long = Array(repeating: line, count: 120).joined(separator: "\n")   // ~12k words
        let chunks = OllamaService.chunks(long)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { wordCount($0) <= 3600 })
        XCTAssertEqual(chunks.joined(separator: "\n"), long)
        var chats = 0
        let http = FakeHTTP { req in
            if req.url!.path.hasSuffix("chat") { chats += 1 }
            return try self.ollama().handler(req)
        }
        let svc = OllamaService(baseURL: URL(string: "http://x")!, model: "qwen2.5:3b", http: http)
        _ = try await svc.minutes(transcript: long, title: "T")
        XCTAssertEqual(chats, chunks.count + 1)
    }

    func testSummaryRespectsEditedActionItems() async throws {
        let (e, p, _, id) = try setup(.success(words(200)), http: ollama())
        await p.process(id)
        XCTAssertEqual(e.store.meta(id)?.actionItems.map(\.text), ["Do it"])
        e.store.update(id) { $0.actionItems = [ActionItem(text: "mine")]; $0.actionItemsEdited = true }
        await p.summarize(id)
        XCTAssertEqual(e.store.meta(id)?.actionItems.map(\.text), ["mine"])
        await p.summarize(id, regenerateActions: true)
        XCTAssertEqual(e.store.meta(id)?.actionItems.map(\.text), ["Do it"])
    }
}

final class ParsingTests: XCTestCase {
    func testActionItemsNeverInventOwnersOrDates() {
        let items = ActionItemParser.parse(Fixtures.minutes)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].owner, "Me"); XCTAssertEqual(items[0].due, "Friday")
        XCTAssertNil(items[1].owner); XCTAssertNil(items[1].due)
        XCTAssertNil(items[2].owner); XCTAssertNil(items[2].due)
        XCTAssertEqual(items[2].text, "Update the roadmap")
    }

    func testNoneStatedYieldsNoItems() {
        XCTAssertTrue(ActionItemParser.parse("## Action items\nNone stated\n").isEmpty)
        XCTAssertTrue(ActionItemParser.parse("## Action items\n- None stated\n## Decisions\n- [Me] not an action (due: Monday)").isEmpty)
        XCTAssertTrue(ActionItemParser.parse("").isEmpty)
    }

    func testSourceRefOnlyWhenTranscriptMatches() {
        let lines = TranscriptFormat.parse(Fixtures.transcript)
        let items = ActionItemParser.attachSources(ActionItemParser.parse(Fixtures.minutes), transcript: lines)
        XCTAssertEqual(items[0].sourceRef, "00:20")
        XCTAssertNil(items[2].sourceRef)
    }

    func testTranscriptMergeFormatParse() {
        let lines = [TranscriptLine(start: 70, who: "Me", text: "b"), TranscriptLine(start: 65, who: "Me", text: "a"),
                     TranscriptLine(start: 10, who: "Others", text: "hi"), TranscriptLine(start: 120, who: "Me", text: "later")]
        let merged = TranscriptFormat.merge(lines)
        XCTAssertEqual(merged.map(\.text), ["hi", "a b", "later"])
        let text = TranscriptFormat.format(merged)
        XCTAssertEqual(text, "[00:10] Others: hi\n[01:05] Me: a b\n[02:00] Me: later\n")
        XCTAssertEqual(TranscriptFormat.parse(text), merged)
    }

    func testStatusLabels() {
        var m = RecordingMetadata(id: UUID(), title: "t", createdAt: Date()); m.phase = .finished
        XCTAssertEqual(m.statusLabel, "Audio only")
        m.transcript = .running; XCTAssertEqual(m.statusLabel, "Transcribing…")
        m.transcript = .done; m.summary = .failed("x"); XCTAssertEqual(m.statusLabel, "Summary failed")
        m.summary = .done; XCTAssertEqual(m.statusLabel, "Ready")
    }
}
