import Foundation

@MainActor enum Exporter {
    static func transcript(_ store: RecordingStore, _ id: UUID) -> String { store.transcriptText(id) }
    static func summary(_ store: RecordingStore, _ id: UUID) -> String { store.read(id, .minutes) }

    static func actions(_ m: RecordingMetadata) -> String {
        var out = "# Action items — \(m.title)\n\n"
        if m.actionItems.isEmpty { return out + "None.\n" }
        for a in m.actionItems {
            var extra: [String] = []
            if let o = a.owner, !o.isEmpty { extra.append("owner: \(o)") }
            if let d = a.due, !d.isEmpty { extra.append("due: \(d)") }
            if let r = a.sourceRef { extra.append("transcript \(r)") }
            out += "- [\(a.done ? "x" : " ")] \(a.text)" + (extra.isEmpty ? "" : " (\(extra.joined(separator: ", ")))") + "\n"
        }
        return out
    }

    static func notes(title: String, text: String) -> String { "# Notes — \(title)\n\n" + text + "\n" }

    static func write(_ text: String, to url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
}
