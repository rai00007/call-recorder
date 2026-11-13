import Foundation

struct MinutesError: LocalizedError { let errorDescription: String? }

protocol HTTPClient { func send(_ request: URLRequest) async throws -> (Data, URLResponse) }
extension URLSession: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) { try await data(for: request) }
}

let minutesSystemPrompt = """
You are a meticulous executive secretary writing minutes of a meeting from a transcript.
Lines are labelled "Me" (the person who recorded the meeting) or "Others" (all other participants, \
not distinguished from each other). The transcript is automatic speech recognition, so expect errors.
Rules: use only information in the transcript. Never invent names, owners, dates or decisions; \
write "not stated" when something is unknown. \
Every point must be traceable to words actually spoken in the transcript; if you cannot point to the line, leave it out. \
If the transcript is casual chatter, a fragment, or has no real meeting content, write "No substantive meeting content." \
under Summary and "None stated" under every other section. Never pad the minutes with plausible-sounding topics. Attribute an action item to "Me" only if Me clearly \
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

func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

struct OllamaService {
    var baseURL: URL
    var model: String
    var http: HTTPClient = URLSession.shared

    func chat(_ system: String, _ user: String, ctx: Int) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false,
            "options": ["num_ctx": ctx, "temperature": 0],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ] as [String: Any])
        let (data, resp) = try await http.send(req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw MinutesError(errorDescription: "Ollama error: " + (String(data: data, encoding: .utf8) ?? "unknown"))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any], let content = msg["content"] as? String
        else { throw MinutesError(errorDescription: "Unexpected response from Ollama") }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checks that Ollama is running and has the model.
    func check() async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags")); req.timeoutInterval = 3
        let data: Data
        do { (data, _) = try await http.send(req) }
        catch { throw MinutesError(errorDescription: "Ollama isn't running. Install it from ollama.com, start it, and run: ollama pull \(model)") }
        let names = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let have = names.compactMap { $0["name"] as? String }
        if !have.contains(where: { $0 == model || $0 == model + ":latest" }) {
            throw MinutesError(errorDescription: "Model \(model) isn't installed. Run: ollama pull \(model)")
        }
    }

    /// Splits a transcript into chunks of at most ~`limit` words on line boundaries.
    static func chunks(_ transcript: String, limit: Int = 3500) -> [String] {
        var out: [String] = [], cur: [String] = [], n = 0
        for l in transcript.split(separator: "\n").map(String.init) {
            if n + wordCount(l) > limit, !cur.isEmpty { out.append(cur.joined(separator: "\n")); cur = []; n = 0 }
            cur.append(l); n += wordCount(l)
        }
        if !cur.isEmpty { out.append(cur.joined(separator: "\n")) }
        return out
    }

    /// Returns the full minutes Markdown (with header).
    func minutes(transcript: String, title: String) async throws -> String {
        let header = "# Meeting minutes — \(title)\n\n"
        // Tiny transcripts give a small model nothing to work with and it invents content, so don't ask it.
        if wordCount(transcript) < 120 {
            return header + "Transcript too short to summarize (under 120 words) — see the transcript.\n"
        }
        try await check()
        let body: String
        if wordCount(transcript) <= 5000 {
            body = try await chat(minutesSystemPrompt, "Transcript:\n\n\(transcript)\n\n\(minutesTemplate)", ctx: 12288)
        } else {
            // Long meeting: condense chunks into notes, then write the minutes from the notes.
            let chunks = Self.chunks(transcript)
            var notes: [String] = []
            for (i, c) in chunks.enumerated() {
                notes.append("### Part \(i + 1) of \(chunks.count)\n" + (try await chat(minutesSystemPrompt,
                    "This is part \(i + 1) of \(chunks.count) of a meeting transcript. List the discussion points, decisions, "
                    + "and action items (with owner and due date if stated) as terse bullets. Keep names and numbers exact.\n\n\(c)", ctx: 8192)))
            }
            body = try await chat(minutesSystemPrompt,
                "Here are condensed notes from consecutive parts of one meeting:\n\n\(notes.joined(separator: "\n\n"))\n\n"
                + "Merge duplicates and write the final minutes.\n\n\(minutesTemplate)", ctx: 12288)
        }
        return header + body + "\n"
    }
}

/// Deterministic parser for the "## Action items" section. Never invents owners or due dates.
enum ActionItemParser {
    private static let unknown: Set<String> = ["", "not stated", "unassigned", "unknown", "none", "n/a", "none stated", "tbd"]

    static func parse(_ minutes: String) -> [ActionItem] {
        var inSection = false
        var items: [ActionItem] = []
        let re = try? NSRegularExpression(pattern: #"^[-*]\s*(?:\[([^\]]*)\])?\s*(.*?)\s*(?:\(\s*due:\s*([^)]*)\))?\s*$"#)
        for raw in minutes.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { inSection = line.lowercased().hasPrefix("## action items"); continue }
            guard inSection, line.hasPrefix("-") || line.hasPrefix("*"),
                  let m = re?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) } }
            guard let text = g(2), !unknown.contains(text.lowercased()) else { continue }
            let owner = g(1).flatMap { unknown.contains($0.lowercased()) ? nil : $0 }
            let due = g(3).flatMap { unknown.contains($0.lowercased()) ? nil : $0 }
            items.append(ActionItem(text: text, owner: owner, due: due))
        }
        return items
    }

    /// Points each item at the transcript line sharing the most distinctive words (needs >= 2), else nil.
    static func attachSources(_ items: [ActionItem], transcript: [TranscriptLine]) -> [ActionItem] {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 })
        }
        return items.map { item in
            var it = item
            let w = words(item.text)
            let best = transcript.map { ($0, words($0.text).intersection(w).count) }.max { $0.1 < $1.1 }
            if let best, best.1 >= 2 { it.sourceRef = best.0.stamp }
            return it
        }
    }
}
