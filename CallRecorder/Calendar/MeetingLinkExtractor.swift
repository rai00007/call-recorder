import Foundation

/// Finds the join link of a meeting. Only http/https links are considered.
/// Known providers are recognised anywhere (URL, location, notes). A generic link only counts when it is the
/// event's URL field or the whole location, so a document link in the notes does not make an event a meeting.
enum MeetingLinkExtractor {
    static let providerDomains = ["meet.google.com", "zoom.us", "zoomgov.com", "zoom.com", "teams.microsoft.com", "teams.live.com",
                                  "webex.com", "whereby.com", "gotomeeting.com", "gotomeet.me", "chime.aws", "meet.jit.si", "bluejeans.com"]

    static func isProvider(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return providerDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func joinLink(url: URL?, location: String?, notes: String?) -> URL? {
        var explicit: [URL] = []
        var found: [URL] = []
        if let u = url, isHTTP(u) { explicit.append(u); found.append(u) }
        if let loc = location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty {
            if !loc.contains(where: \.isWhitespace), let u = URL(string: loc), isHTTP(u) { explicit.append(u); found.append(u) }
            found += links(in: loc)
        }
        if let n = notes, !n.isEmpty { found += links(in: n) }
        return found.first(where: isProvider) ?? explicit.first
    }

    private static func isHTTP(_ u: URL) -> Bool { ["http", "https"].contains(u.scheme?.lowercased() ?? "") && u.host != nil }

    private static func links(in text: String) -> [URL] {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return det.matches(in: text, range: range).compactMap { $0.url }.filter(isHTTP)
    }
}
