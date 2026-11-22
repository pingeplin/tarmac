import Foundation

/// One item of a list: its marker as written (`•` for `-`, `*` or `+`; an
/// ordered one keeps its number) and its text.
public struct ListItem: Equatable, Sendable {
    public let marker: String
    public let text: InlineText

    public init(marker: String, text: InlineText) {
        self.marker = marker
        self.text = text
    }

    static let bullet = "•"

    var isOrdered: Bool { marker != Self.bullet }
}

/// A block of a report's text (spec 2611.0018 D1). A code block keeps its
/// lines as written.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(InlineText)
    case heading(InlineText)
    case list([ListItem])
    case code([String])
}

/// The block rules of a report's text (specs 2611.0017 D2, 2611.0018 D1).
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
            .makeIterator()
        var builder = Builder()
        while let line = lines.next() {
            switch Line(line) {
            case .fence:
                var body: [String] = []
                while let next = lines.next(), !Line.closesFence(next) { body.append(String(next)) }
                builder.code(body)
            case .heading(let source): builder.heading(source)
            case .item(let marker, let source): builder.item(marker, source)
            case .blank: builder.end()
            case .text(let source): builder.text(source)
            }
        }
        builder.end()
        return builder.blocks
    }

    /// What one line of the source is; the first rule that fits, in this order.
    private enum Line {
        case fence
        case heading(Substring)
        case item(marker: String, Substring)
        case blank
        case text(Substring)

        init(_ line: Substring) {
            if Self.opensFence(line) {
                self = .fence
            } else if let heading = Self.heading(line) {
                self = .heading(heading)
            } else if let (marker, rest) = Self.listItem(line) {
                self = .item(marker: marker, rest)
            } else if line.allSatisfy(\.isWhitespace) {
                self = .blank
            } else {
                self = .text(line)
            }
        }

        /// A fence opens at a line that starts with three backticks and has
        /// no backtick after that run: CommonMark allows none in an info
        /// string, and a line that closes its own backticks is text (#426).
        private static func opensFence(_ line: Substring) -> Bool {
            closesFence(line) && !line.drop { $0 == "`" }.contains("`")
        }

        /// A fence closes at the next line that starts with three backticks.
        static func closesFence(_ line: Substring) -> Bool { line.hasPrefix("```") }

        private static func heading(_ line: Substring) -> Substring? {
            let hashes = line.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes) else { return nil }
            let rest = line.dropFirst(hashes)
            guard let first = rest.first, first.isWhitespace else { return nil }
            return rest
        }

        private static func listItem(_ line: Substring) -> (String, Substring)? {
            let body = line.drop { $0.isWhitespace }
            let mark: String
            let width: Int
            if let first = body.first, "-*+".contains(first) {
                (mark, width) = (ListItem.bullet, 1)
            } else {
                let digits = body.prefix { $0.isASCII && $0.isNumber }
                let after = body.dropFirst(digits.count)
                guard !digits.isEmpty, let close = after.first, close == "." || close == ")" else { return nil }
                (mark, width) = (String(body.prefix(digits.count + 1)), digits.count + 1)
            }
            let rest = body.dropFirst(width)
            guard let gap = rest.first, gap.isWhitespace else { return nil }
            return (mark, rest)
        }
    }

    /// The blocks so far, and the paragraph or the list that is still open.
    private struct Builder {
        private(set) var blocks: [MarkdownBlock] = []
        private var paragraph: [Substring] = []
        private var list: [ListItem] = []

        mutating func text(_ line: Substring) {
            endList()
            paragraph.append(line)
        }

        mutating func item(_ marker: String, _ source: Substring) {
            endParagraph()
            let item = ListItem(marker: marker, text: InlineMarks.text(source))
            if let last = list.last, last.isOrdered != item.isOrdered { endList() }
            list.append(item)
        }

        mutating func heading(_ source: Substring) {
            end()
            let text = InlineMarks.text(source)
            if !text.runs.isEmpty { blocks.append(.heading(text)) }
        }

        mutating func code(_ body: [String]) {
            end()
            if !body.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) { blocks.append(.code(body)) }
        }

        mutating func end() {
            endParagraph()
            endList()
        }

        private mutating func endParagraph() {
            let text = InlineMarks.text(paragraph.joined(separator: " "))
            if !text.runs.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        private mutating func endList() {
            if !list.isEmpty { blocks.append(.list(list)) }
            list = []
        }
    }
}
