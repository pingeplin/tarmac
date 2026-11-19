import CoreGraphics

public enum InlineMark: Equatable, Sendable {
    case plain, bold, italic, code, link, bullet
}

public struct InlineRun: Equatable, Sendable {
    public let text: String
    public let mark: InlineMark

    public init(_ text: String, _ mark: InlineMark) {
        self.text = text
        self.mark = mark
    }
}

/// One line of runs, each with one mark (spec 2611.0017 D7). It is always in
/// normal form: no empty run, and no two plain runs side by side.
public struct InlineText: Equatable, Sendable {
    public let runs: [InlineRun]

    public init(_ runs: [InlineRun]) {
        var joined: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if run.mark == .plain, let last = joined.last, last.mark == .plain {
                joined[joined.count - 1] = InlineRun(last.text + run.text, .plain)
            } else {
                joined.append(run)
            }
        }
        self.runs = joined
    }

    public var plain: String { runs.map(\.text).joined() }

    public static func literal(_ text: String) -> InlineText { InlineText([InlineRun(text, .plain)]) }

    public static func + (lhs: InlineText, rhs: InlineText) -> InlineText { InlineText(lhs.runs + rhs.runs) }

    public var quoted: InlineText { InlineText([InlineRun("“", .plain)] + runs + [InlineRun("”", .plain)]) }

    /// At most `limit` Unicode scalars: the first `limit − 1` and a plain `…`
    /// when the text is longer. The pill's rule.
    public func prefix(scalars limit: Int) -> InlineText {
        prefix(limit, count: { $0.unicodeScalars.count }, take: { String($0.unicodeScalars.prefix($1)) })
    }

    /// The same rule in `Character`s, so a cut never splits a grapheme. The row's rule.
    public func prefix(characters limit: Int) -> InlineText {
        prefix(limit, count: \.count, take: { String($0.prefix($1)) })
    }

    /// The longest `prefix(characters:)` that `measure` finds no wider than
    /// `room`; at least a `…`. The row's cut to its width.
    public func prefix(fitting room: CGFloat, measure: (InlineText) -> CGFloat) -> InlineText {
        guard measure(self) > room else { return self }
        var fits = 1
        var low = 1
        var high = runs.reduce(0) { $0 + $1.text.count } - 1
        while low <= high {
            let mid = (low + high) / 2
            if measure(prefix(characters: mid)) <= room {
                fits = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return prefix(characters: fits)
    }

    private func prefix(_ limit: Int, count: (String) -> Int, take: (String, Int) -> String) -> InlineText {
        guard runs.reduce(0, { $0 + count($1.text) }) > limit else { return self }
        var left = max(limit, 1) - 1
        var kept: [InlineRun] = []
        for run in runs where left > 0 {
            let taken = min(left, count(run.text))
            kept.append(InlineRun(take(run.text, taken), run.mark))
            left -= taken
        }
        return InlineText(kept + [InlineRun("…", .plain)])
    }
}

/// One item of a list: its marker as written (`•` for `-`, `*` or `+`; an
/// ordered one keeps its number) and its text.
public struct ListItem: Equatable, Sendable {
    public let marker: String
    public let text: InlineText

    public init(marker: String, text: InlineText) {
        self.marker = marker
        self.text = text
    }

    var isOrdered: Bool { marker != "•" }
}

/// A block of a report's text (spec 2611.0018 D1). A code block keeps its
/// lines as written.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(InlineText)
    case heading(InlineText)
    case list([ListItem])
    case code([String])
}

/// A report's text as one line of inline marks (spec 2611.0017 D2–D6), or as
/// blocks (spec 2611.0018 D1). Both read the same block rules.
public enum InlineMarkdown {
    public static func line(_ text: String) -> InlineText {
        let runs = blocks(text).map(flat).filter { !$0.isEmpty }.joined(separator: [InlineRun(" ", .plain)])
        let rendered = settle(InlineText(Array(runs)))
        return rendered.runs.isEmpty ? .literal(ChromeText.oneLine(text)) : rendered
    }

    // MARK: - Blocks (2611.0017 D2, 2611.0018 D1)

    public static func blocks(_ text: String) -> [MarkdownBlock] {
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        var list: [ListItem] = []
        func endParagraph() {
            let text = settle(InlineText(inline(paragraph.joined(separator: " "))))
            if !text.runs.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        func endList() {
            if !list.isEmpty { blocks.append(.list(list)) }
            list = []
        }
        func end() {
            endParagraph()
            endList()
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.hasPrefix("```") {
                end()
                var body: [String] = []
                while index < lines.count, !lines[index].hasPrefix("```") {
                    body.append(String(lines[index]))
                    index += 1
                }
                index += 1
                if !body.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) { blocks.append(.code(body)) }
            } else if let heading = heading(line) {
                end()
                let text = settle(InlineText(inline(heading)))
                if !text.runs.isEmpty { blocks.append(.heading(text)) }
            } else if let (mark, rest) = listItem(line) {
                endParagraph()
                let item = ListItem(marker: mark, text: settle(InlineText(inline(rest))))
                if let last = list.last, last.isOrdered != item.isOrdered { endList() }
                list.append(item)
            } else if line.allSatisfy(\.isWhitespace) {
                end()
            } else {
                endList()
                paragraph.append(line)
            }
        }
        end()
        return blocks
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
            (mark, width) = ("•", 1)
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

    // MARK: - Inline marks (D3)

    private static func inline(_ text: some StringProtocol) -> [InlineRun] {
        let chars = Array(text)
        var runs: [InlineRun] = []
        var plain = ""
        var index = 0
        while index < chars.count {
            if let (run, next) = code(chars, index) ?? link(chars, index) ?? emphasis(chars, index) {
                runs.append(InlineRun(plain, .plain))
                runs.append(run)
                plain = ""
                index = next
            } else {
                plain.append(chars[index])
                index += 1
            }
        }
        runs.append(InlineRun(plain, .plain))
        return runs
    }

    private static func code(_ chars: [Character], _ start: Int) -> (InlineRun, Int)? {
        guard chars[start] == "`", let end = chars[(start + 1)...].firstIndex(of: "`") else { return nil }
        return span(chars[(start + 1)..<end], .code, next: end + 1)
    }

    private static func link(_ chars: [Character], _ start: Int) -> (InlineRun, Int)? {
        guard chars[start] == "[", let close = chars[(start + 1)...].firstIndex(of: "]"),
              close + 1 < chars.count, chars[close + 1] == "(",
              let end = chars[(close + 2)...].firstIndex(of: ")") else { return nil }
        return span(chars[(start + 1)..<close], .link, next: end + 1)
    }

    /// A code span or a link: its content trimmed, and none when that is empty.
    private static func span(_ content: ArraySlice<Character>, _ mark: InlineMark, next: Int) -> (InlineRun, Int)? {
        let text = trimmed(content)
        return text.isEmpty ? nil : (InlineRun(text, mark), next)
    }

    private static func emphasis(_ chars: [Character], _ start: Int) -> (InlineRun, Int)? {
        for (mark, count): (Character, Int) in [("*", 2), ("_", 2), ("*", 1), ("_", 1)] {
            if let found = emphasis(chars, start, mark: mark, count: count) { return found }
        }
        return nil
    }

    private static func emphasis(_ chars: [Character], _ start: Int, mark: Character, count: Int) -> (InlineRun, Int)? {
        let underscore = mark == "_"
        func isMark(_ at: Int) -> Bool {
            at + count <= chars.count && chars[at..<(at + count)].allSatisfy { $0 == mark }
        }
        guard isMark(start), !(underscore && insideWord(chars, neighbour: start - 1, away: -1)) else { return nil }
        let open = start + count
        guard let close = (open..<chars.count).first(where: {
            isMark($0) && !(underscore && insideWord(chars, neighbour: $0 + count, away: 1))
        }) else { return nil }
        let content = chars[open..<close]
        guard let first = content.first, let last = content.last, !first.isWhitespace, !last.isWhitespace else {
            return nil
        }
        return (InlineRun(String(content), count == 2 ? .bold : .italic), close + count)
    }

    /// The `_` word test: a neighbour that is a letter, a digit or `_`, or a
    /// `.` with a letter or digit on its other side, puts the mark inside a word.
    private static func insideWord(_ chars: [Character], neighbour: Int, away: Int) -> Bool {
        guard chars.indices.contains(neighbour) else { return false }
        let char = chars[neighbour]
        if char.isLetter || char.isNumber || char == "_" { return true }
        let beyond = neighbour + away
        return char == "." && chars.indices.contains(beyond) && (chars[beyond].isLetter || chars[beyond].isNumber)
    }

    private static func trimmed(_ chars: ArraySlice<Character>) -> String {
        String(chars.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
    }

    // MARK: - Whitespace (D4)

    private static func settle(_ text: InlineText) -> InlineText {
        var runs = text.runs.map { InlineRun(collapsed($0.text), $0.mark) }
        if let first = runs.first, first.text.hasPrefix(" ") {
            runs[0] = InlineRun(String(first.text.dropFirst()), first.mark)
        }
        if let last = runs.last, last.text.hasSuffix(" ") {
            runs[runs.count - 1] = InlineRun(String(last.text.dropLast()), last.mark)
        }
        return InlineText(runs)
    }

    private static func collapsed(_ text: String) -> String {
        var out = ""
        for char in text {
            if char.isWhitespace {
                if !out.hasSuffix(" ") { out.append(" ") }
            } else {
                out.append(char)
            }
        }
        return out
    }
}
