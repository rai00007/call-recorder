import SwiftUI

/// Renders generated minutes as headings, bullets and checkboxes instead of raw Markdown.
struct MarkdownView: View {
    let markdown: String
    var body: some View {
        let blocks = MarkdownBlocks.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let l, let t):
            inline(t).font(l <= 1 ? .title2.bold() : l == 2 ? .headline : .subheadline.bold())
                .foregroundStyle(l <= 2 ? Theme.text : Theme.secondary)
                .padding(.top, l <= 2 ? 8 : 2).accessibilityAddTraits(.isHeader)
        case .bullet(let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.accent); inline(t)
            }.padding(.leading, CGFloat(indent) * 16)
        case .check(let done, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? Theme.accent : Theme.secondary)
                inline(t)
            }.accessibilityElement(children: .combine).accessibilityValue(done ? "done" : "not done")
        case .paragraph(let t): inline(t).foregroundStyle(Theme.text)
        }
    }
}
