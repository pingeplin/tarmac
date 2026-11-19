/// A report's text as one line of inline marks (spec 2611.0017 D2–D6): its
/// blocks, joined by one space.
public enum InlineMarkdown {
    public static func line(_ text: String) -> InlineText {
        let runs = MarkdownBlocks.parse(text).map(flat).filter { !$0.isEmpty }.joined(separator: [InlineRun(" ", .plain)])
        let rendered = InlineText(Array(runs)).settled
        return rendered.runs.isEmpty ? .literal(ChromeText.oneLine(text)) : rendered
    }

    /// A block as `line` shows it: a list item is its marker, a space and
    /// its text; a code block is one code run.
    private static func flat(_ block: MarkdownBlock) -> [InlineRun] {
        let gap = InlineRun(" ", .plain)
        switch block {
        case .paragraph(let text), .heading(let text):
            return text.runs
        case .list(let items):
            return Array(items.map { [InlineRun($0.marker, .bullet), gap] + $0.text.runs }.joined(separator: [gap]))
        case .code(let lines):
            return InlineText([InlineRun(ChromeText.oneLine(lines.joined(separator: " ")), .code)]).runs
        }
    }
}
