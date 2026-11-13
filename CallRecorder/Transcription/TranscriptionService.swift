import Foundation
import Speech
import AVFoundation

typealias Segment = (start: TimeInterval, text: String)

struct TranscriptLine: Equatable {
    var start: TimeInterval
    var who: String
    var text: String
    var stamp: String { String(format: "%02d:%02d", Int(start) / 60, Int(start) % 60) }
}

struct TranscriptionError: LocalizedError { let errorDescription: String? }

enum TranscriptFormat {
    /// Sorts by time and merges consecutive lines of the same speaker (<30s apart) into one turn.
    static func merge(_ input: [TranscriptLine]) -> [TranscriptLine] {
        var turns: [TranscriptLine] = []
        for l in input.sorted(by: { $0.start < $1.start }) {
            if let last = turns.last, last.who == l.who, l.start - last.start < 30 {
                turns[turns.count - 1].text += " " + l.text
            } else { turns.append(l) }
        }
        return turns
    }

    static func format(_ turns: [TranscriptLine]) -> String {
        turns.map { "[\($0.stamp)] \($0.who): \($0.text)" }.joined(separator: "\n") + "\n"
    }

    /// Parses "[mm:ss] Who: text" lines; other lines are ignored.
    static func parse(_ text: String) -> [TranscriptLine] {
        guard let re = try? NSRegularExpression(pattern: #"^\[(\d+):(\d{2})\] ([^:]+): (.*)$"#) else { return [] }
        return text.split(separator: "\n").compactMap { sub in
            let s = String(sub)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let mm = Range(m.range(at: 1), in: s), let ss = Range(m.range(at: 2), in: s),
                  let w = Range(m.range(at: 3), in: s), let t = Range(m.range(at: 4), in: s)
            else { return nil }
            return TranscriptLine(start: Double((Int(s[mm]) ?? 0) * 60 + (Int(s[ss]) ?? 0)), who: String(s[w]), text: String(s[t]))
        }
    }
}

/// Seam for tests; the real implementation is `AppleSpeechTranscriber`.
protocol Transcriber {
    /// `tracks` are (audio file, speaker label). Returns formatted transcript text.
    func transcribe(tracks: [(url: URL, who: String)], language: String) async throws -> String
}

struct AppleSpeechTranscriber: Transcriber {
    func transcribe(tracks: [(url: URL, who: String)], language: String) async throws -> String {
        var lines: [TranscriptLine] = []
        for (url, who) in tracks where FileManager.default.fileExists(atPath: url.path) {
            for seg in try await transcribeSegments(url, language: language) {
                let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { lines.append(TranscriptLine(start: seg.start, who: who, text: t)) }
            }
        }
        guard !lines.isEmpty else { throw TranscriptionError(errorDescription: "No speech was detected in the recording.") }
        return TranscriptFormat.format(TranscriptFormat.merge(lines))
    }
}

/// Transcribes one audio file into timed segments (on-device SpeechAnalyzer).
func transcribeSegments(_ url: URL, language: String) async throws -> [Segment] {
    let locale = Locale(identifier: language)
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
        try await req.downloadAndInstall()   // one-time model download
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
