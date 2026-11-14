import Foundation

enum MDBlock: Equatable {
    case heading(Int, String)
    case bullet(String, indent: Int)
    case check(Bool, String)
    case paragraph(String)
}

/// Minimal Markdown block parser for rendering generated minutes (headings, bullets, checkboxes, paragraphs).
enum MarkdownBlocks {
    static func parse(_ md: String) -> [MDBlock] {
        md.components(separatedBy: "\n").compactMap { raw in
            let indent = raw.prefix { $0 == " " }.count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if (1...6).contains(level), !text.isEmpty { return .heading(level, text) }
            }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                let rest = String(line.dropFirst(marker.count))
                if rest.hasPrefix("[ ] ") { return .check(false, String(rest.dropFirst(4))) }
                if rest.lowercased().hasPrefix("[x] ") { return .check(true, String(rest.dropFirst(4))) }
                return .bullet(rest, indent: indent)
            }
            return .paragraph(line)
        }
    }
}
