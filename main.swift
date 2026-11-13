// CallRecorder — menu-bar app: record system audio (other participants) + mic into one m4a,
// then transcribe on-device. macOS 26+.
//
import Foundation
import ScreenCaptureKit
import AVFoundation
import Speech
import AppKit

// recordings/ lives next to CallRecorder.app (i.e. inside this repo)
let outDir = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("recordings")

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

// MARK: - Transcription (on-device, SpeechAnalyzer)
typealias Segment = (start: TimeInterval, text: String)

/// Transcribes one audio file into timed segments.
func transcribeSegments(_ url: URL) async throws -> [Segment] {
    let locale = Locale(identifier: "en-US")
    // SpeechTranscriber isn't offered on every Mac (isAvailable == false, no supported locales);
    // DictationTranscriber works there, so fall back to it.
    let module: any SpeechModule
    let collect: @Sendable () async throws -> [Segment]
    if SpeechTranscriber.isAvailable,
       await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                  reportingOptions: [], attributeOptions: [.audioTimeRange])
        module = t
        collect = {
            var out: [Segment] = []
            for try await r in t.results {
                out.append((r.text.runs.first?.audioTimeRange?.start.seconds ?? 0, String(r.text.characters)))
            }
            return out
        }
    } else {
        let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                     reportingOptions: [], attributeOptions: [.audioTimeRange])
        module = t
        collect = {
            var out: [Segment] = []
            for try await r in t.results {
                out.append((r.text.runs.first?.audioTimeRange?.start.seconds ?? 0, String(r.text.characters)))
            }
            return out
        }
    }
    if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        print("Downloading speech model (one time)…")
        try await req.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [module])
    let file = try AVAudioFile(forReading: url)
    async let results = collect()
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await results
}

/// Transcribes the system-audio track ("Others") and mic track ("Me") separately and
/// interleaves them by time. Returns the path of the written .txt.
func transcribe(sys: URL, mic: URL, final: URL) async throws -> URL {
    var lines: [(start: TimeInterval, who: String, text: String)] = []
    for (url, who) in [(sys, "Others"), (mic, "Me")] where FileManager.default.fileExists(atPath: url.path) {
        for seg in try await transcribeSegments(url) {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append((seg.start, who, t)) }
        }
    }
    lines.sort { $0.start < $1.start }
    // Merge consecutive lines from the same speaker into one turn.
    var turns: [(start: TimeInterval, who: String, text: String)] = []
    for l in lines {
        if let last = turns.last, last.who == l.who, l.start - last.start < 30 {
            turns[turns.count - 1].text += " " + l.text
        } else { turns.append(l) }
    }
    let text = turns.map { String(format: "[%02d:%02d] %@: %@", Int($0.start) / 60, Int($0.start) % 60, $0.who, $0.text) }
        .joined(separator: "\n") + "\n"
    let txt = final.deletingPathExtension().appendingPathExtension("txt")
    try text.write(to: txt, atomically: true, encoding: .utf8)
    return txt
}

// MARK: - Meeting minutes (local LLM via Ollama)
let ollamaURL = URL(string: ProcessInfo.processInfo.environment["OLLAMA_HOST_URL"] ?? "http://localhost:11434")!
let minutesModel = ProcessInfo.processInfo.environment["CALLREC_MODEL"] ?? "qwen2.5:3b"

struct MinutesError: LocalizedError { let errorDescription: String? }

let minutesSystemPrompt = """
You are a meticulous executive secretary writing minutes of a meeting from a transcript.
Lines are labelled "Me" (the person who recorded the meeting) or "Others" (all other participants, \
not distinguished from each other). The transcript is automatic speech recognition, so expect errors.
Rules: use only information in the transcript. Never invent names, owners, dates or decisions; \
write "not stated" when something is unknown. Attribute an action item to "Me" only if Me clearly \
took it on, otherwise to "Others" or "Unassigned". Be concise and factual.
"""

let minutesTemplate = """
Write the minutes in Markdown with exactly these sections:

## Summary
2-4 sentences on what the meeting was about and its outcome.

## Key discussion points
Bullet list, grouped by topic.

## Decisions
Bullet list, or "None stated".

## Action items
Bullet list as "- [owner] task (due: date or not stated)", or "None stated".

## Open questions / follow-ups
Bullet list, or "None".
"""

func chat(_ system: String, _ user: String, ctx: Int) async throws -> String {
    var req = URLRequest(url: ollamaURL.appendingPathComponent("api/chat"))
    req.httpMethod = "POST"
    req.timeoutInterval = 3600
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": minutesModel, "stream": false,
        "options": ["num_ctx": ctx, "temperature": 0.2],
        "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
    ] as [String: Any])
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
        throw MinutesError(errorDescription: "Ollama error: " + (String(data: data, encoding: .utf8) ?? "unknown"))
    }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let msg = obj["message"] as? [String: Any], let content = msg["content"] as? String
    else { throw MinutesError(errorDescription: "Unexpected response from Ollama") }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Checks that Ollama is running and has the model.
func checkOllama() async throws {
    var req = URLRequest(url: ollamaURL.appendingPathComponent("api/tags")); req.timeoutInterval = 3
    let data: Data
    do { (data, _) = try await URLSession.shared.data(for: req) }
    catch { throw MinutesError(errorDescription: "Ollama isn't running. Install it from ollama.com, start it, and run: ollama pull \(minutesModel)") }
    let names = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
    let have = names.compactMap { $0["name"] as? String }
    if !have.contains(where: { $0 == minutesModel || $0 == minutesModel + ":latest" }) {
        throw MinutesError(errorDescription: "Model \(minutesModel) isn't installed. Run: ollama pull \(minutesModel)")
    }
}

func summarize(transcript: String, to out: URL) async throws {
    try await checkOllama()
    let lines = transcript.split(separator: "\n").map(String.init)
    let wordCount = { (s: String) in s.split(whereSeparator: \.isWhitespace).count }
    var minutes: String
    if wordCount(transcript) <= 5000 {
        minutes = try await chat(minutesSystemPrompt, "Transcript:\n\n\(transcript)\n\n\(minutesTemplate)", ctx: 12288)
    } else {
        // Long meeting: condense chunks into notes, then write the minutes from the notes.
        var chunks: [String] = [], cur: [String] = [], n = 0
        for l in lines {
            if n + wordCount(l) > 3500, !cur.isEmpty { chunks.append(cur.joined(separator: "\n")); cur = []; n = 0 }
            cur.append(l); n += wordCount(l)
        }
        if !cur.isEmpty { chunks.append(cur.joined(separator: "\n")) }
        var notes: [String] = []
        for (i, c) in chunks.enumerated() {
            notes.append("### Part \(i + 1) of \(chunks.count)\n" + (try await chat(minutesSystemPrompt,
                "This is part \(i + 1) of \(chunks.count) of a meeting transcript. List the discussion points, decisions, "
                + "and action items (with owner and due date if stated) as terse bullets. Keep names and numbers exact.\n\n\(c)", ctx: 8192)))
        }
        minutes = try await chat(minutesSystemPrompt,
            "Here are condensed notes from consecutive parts of one meeting:\n\n\(notes.joined(separator: "\n\n"))\n\n"
            + "Merge duplicates and write the final minutes.\n\n\(minutesTemplate)", ctx: 12288)
    }
    let header = "# Meeting minutes — \(out.deletingPathExtension().deletingPathExtension().lastPathComponent)\n\n"
    try (header + minutes + "\n").write(to: out, atomically: true, encoding: .utf8)
}

// MARK: - Recording
final class AudioFile {
    let writer: AVAssetWriter, input: AVAssetWriterInput
    var started = false
    init(_ url: URL) throws {
        writer = try AVAssetWriter(url: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }
    func append(_ sb: CMSampleBuffer) {
        guard sb.isValid, CMSampleBufferGetNumSamples(sb) > 0 else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb) }
    }
    func finish() async {
        guard started else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let sys: AudioFile, mic: AudioFile
    let queue = DispatchQueue(label: "callrec.samples")
    var stream: SCStream?
    init(sys: AudioFile, mic: AudioFile) { self.sys = sys; self.mic = mic }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw NSError(domain: "callrec", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"]) }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.captureMicrophone = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2   // we only want audio
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }
    func stop() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { c in queue.async { c.resume() } }
        await sys.finish(); await mic.finish()
    }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: sys.append(sb)
        case .microphone: mic.append(sb)
        default: break
        }
    }
    func stream(_ s: SCStream, didStopWithError error: Error) { print("Stream stopped: \(error)") }
}

func mix(_ a: URL, _ b: URL, to out: URL) async throws {
    let comp = AVMutableComposition()
    for u in [a, b] where FileManager.default.fileExists(atPath: u.path) {
        let asset = AVURLAsset(url: u)
        guard let src = try await asset.loadTracks(withMediaType: .audio).first,
              let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { continue }
        try t.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: src, at: .zero)
    }
    guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { throw NSError(domain: "callrec", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export failed"]) }
    try await ex.export(to: out, as: .m4a)
}

// MARK: - Menu-bar app
final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let status = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    let startItem = NSMenuItem(title: "Start Recording", action: #selector(start), keyEquivalent: "s")
    let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stop), keyEquivalent: "x")
    var rec: Recorder?
    var urls: (sys: URL, mic: URL, final: URL)?
    var busy = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        status.isEnabled = false
        for i in [status, .separator(), startItem, stopItem, .separator()] { menu.addItem(i) }
        menu.addItem(NSMenuItem(title: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        render()
    }

    func render(_ text: String? = nil) {
        let recording = rec != nil
        item.button?.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "record.circle",
                                     accessibilityDescription: "Call Recorder")
        item.button?.contentTintColor = recording ? .systemRed : nil
        startItem.isEnabled = !recording && !busy
        stopItem.isEnabled = recording
        status.title = text ?? (recording ? "Recording…" : "Idle")
    }

    func alert(_ msg: String) {
        let a = NSAlert(); a.messageText = "Call Recorder"; a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    @objc func start() {
        do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
        catch { alert("Can't create \(outDir.path): \(error)"); return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "call_" + f.string(from: Date())
        let u = (sys: outDir.appendingPathComponent(base + ".system.tmp.m4a"),
                 mic: outDir.appendingPathComponent(base + ".mic.tmp.m4a"),
                 final: outDir.appendingPathComponent(base + ".m4a"))
        busy = true; render("Starting…")
        Task { @MainActor in
            defer { busy = false }
            do {
                let r = Recorder(sys: try AudioFile(u.sys), mic: try AudioFile(u.mic))
                try await r.start()
                rec = r; urls = u
            } catch {
                alert("Could not start recording: \(error.localizedDescription)\n\nGrant Screen & System Audio Recording and Microphone permission to Call Recorder in System Settings → Privacy & Security, then try again.")
            }
            render()
        }
    }

    @objc func stop() { Task { @MainActor in await finish(transcribeAfter: true) } }

    @MainActor func finish(transcribeAfter: Bool) async {
        guard let r = rec, let u = urls else { return }
        rec = nil; busy = true; render("Saving…")
        await r.stop()
        do { try await mix(u.sys, u.mic, to: u.final) }
        catch { alert("Saving failed: \(error.localizedDescription)"); busy = false; render(); return }
        if transcribeAfter {
            render("Transcribing…")
            do {
                let txt = try await transcribe(sys: u.sys, mic: u.mic, final: u.final)
                try? FileManager.default.removeItem(at: u.sys)
                try? FileManager.default.removeItem(at: u.mic)
                render("Writing minutes…")
                do {
                    let transcript = try String(contentsOf: txt, encoding: .utf8)
                    try await summarize(transcript: transcript,
                                        to: u.final.deletingPathExtension().appendingPathExtension("minutes.md"))
                } catch { alert("Minutes not written: \(error.localizedDescription)\n\nThe recording and transcript are saved.") }
            } catch { alert("Transcription failed (\(error.localizedDescription)). The recording is saved.") }
        } else {
            try? FileManager.default.removeItem(at: u.sys)
            try? FileManager.default.removeItem(at: u.mic)
        }
        busy = false; render("Saved \(u.final.lastPathComponent)")
        NSWorkspace.shared.activateFileViewerSelecting([u.final])
    }

    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outDir)
    }

    @objc func quit() {
        guard rec != nil else { NSApp.terminate(nil); return }
        Task { @MainActor in await finish(transcribeAfter: false); NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
