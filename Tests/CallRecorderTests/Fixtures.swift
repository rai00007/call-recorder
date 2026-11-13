import Foundation
import AVFoundation
@testable import CallRecorderCore

enum Fixtures {
    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("crtests-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Synthetic sine-wave m4a (no real audio).
    static func makeAudio(_ url: URL, seconds: Double = 1) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        let frames = AVAudioFrameCount(44100 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
        try file.write(from: buf)
    }

    static let transcript = """
    [00:05] Others: Let's ship the mobile launch on December fifth.
    [00:20] Me: I will send the launch checklist to everyone by Friday.
    """

    static let minutes = """
    # Meeting minutes — Test

    ## Summary
    Launch planning.

    ## Action items
    - [Me] Send the launch checklist to everyone (due: Friday)
    - [Unassigned] Review the QA schedule (due: not stated)
    - Update the roadmap

    ## Open questions / follow-ups
    - None
    """
}

struct FakeHTTP: HTTPClient {
    var handler: (URLRequest) throws -> (Data, Int)
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (d, code) = try handler(request)
        return (d, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    var result: Result<String, Error>
    var calls = 0
    var lastTracks: [String] = []
    init(_ r: Result<String, Error>) { result = r }
    func transcribe(tracks: [(url: URL, who: String)], language: String) async throws -> String {
        calls += 1; lastTracks = tracks.map(\.who)
        return try result.get()
    }
}

final class FakeSession: CaptureSession {
    var onError: ((Error) -> Void)?
    var micActive = true, systemActive = true, droppedBuffers = 0
    var failStart: Error?
    var writeFiles: [URL] = []
    func start() async throws { if let e = failStart { throw e } }
    func stop() async { for u in writeFiles { try? Fixtures.makeAudio(u) } }
}

@MainActor
struct Env {
    let dir = Fixtures.tempDir()
    let trashDir = Fixtures.tempDir()
    let defaults = UserDefaults(suiteName: "crtests-" + UUID().uuidString)!
    var store: RecordingStore
    var settings: AppSettings

    init() {
        let t = trashDir
        store = RecordingStore(root: dir.appendingPathComponent("lib"), trash: { u in
            try FileManager.default.moveItem(at: u, to: t.appendingPathComponent(UUID().uuidString + "-" + u.lastPathComponent))
        })
        settings = AppSettings(defaults: defaults)
    }
}
