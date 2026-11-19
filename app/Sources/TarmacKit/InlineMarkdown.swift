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
        prefix(limit) { $0.unicodeScalars.map(String.init) }
    }

    /// The same rule in `Character`s, so a cut never splits a grapheme. The row's rule.
    public func prefix(characters limit: Int) -> InlineText {
        prefix(limit) { $0.map(String.init) }
    }

    private func prefix(_ limit: Int, units: (String) -> [String]) -> InlineText {
        let split = runs.map { (units: units($0.text), mark: $0.mark) }
        guard split.reduce(0, { $0 + $1.units.count }) > limit else { return self }
        var left = max(limit, 1) - 1
        var kept: [InlineRun] = []
        for run in split where left > 0 {
            let count = min(left, run.units.count)
            kept.append(InlineRun(run.units.prefix(count).joined(), run.mark))
            left -= count
        }
        return InlineText(kept + [InlineRun("…", .plain)])
    }
}

/// A report's text as one line of inline marks (spec 2611.0017 D2–D6).
public enum InlineMarkdown {
    public static func line(_ text: String) -> InlineText {
        let rendered = settle(InlineText(blocks(text)))
        return rendered.runs.isEmpty ? .literal(ChromeText.oneLine(text)) : rendered
    }

    // MARK: - Blocks (D2)

    private static func blocks(_ text: String) -> [InlineRun] {
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        var blocks: [[InlineRun]] = []
        var paragraph: [Substring] = []
        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(inline(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.hasPrefix("```") {
                endParagraph()
                var body: [Substring] = []
                while index < lines.count, !lines[index].hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append([InlineRun(ChromeText.oneLine(body.joined(separator: " ")), .code)])
            } else if let heading = heading(line) {
                endParagraph()
                blocks.append(inline(heading))
            } else if let (mark, rest) = listItem(line) {
                endParagraph()
                blocks.append([InlineRun(mark, .bullet), InlineRun(" ", .plain)] + inline(rest))
            } else if line.allSatisfy(\.isWhitespace) {
                endParagraph()
            } else {
                paragraph.append(line)
            }
        }
        endParagraph()
        return Array(blocks.map { InlineText($0).runs }.filter { !$0.isEmpty }.joined(separator: [InlineRun(" ", .plain)]))
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
        let mark: Substring
        if let first = body.first, "-*+".contains(first) {
            mark = body.prefix(1)
        } else {
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            let after = body.dropFirst(digits.count)
            guard !digits.isEmpty, let close = after.first, close == "." || close == ")" else { return nil }
            mark = body.prefix(digits.count + 1)
        }
        let rest = body.dropFirst(mark.count)
        guard let gap = rest.first, gap.isWhitespace else { return nil }
        return (mark == "-" || mark == "*" || mark == "+" ? "•" : String(mark), rest)
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
        let content = trimmed(chars[(start + 1)..<end])
        return content.isEmpty ? nil : (InlineRun(content, .code), end + 1)
    }

    private static func link(_ chars: [Character], _ start: Int) -> (InlineRun, Int)? {
        guard chars[start] == "[", let close = chars[(start + 1)...].firstIndex(of: "]"),
              close + 1 < chars.count, chars[close + 1] == "(",
              let end = chars[(close + 2)...].firstIndex(of: ")") else { return nil }
        let content = trimmed(chars[(start + 1)..<close])
        return content.isEmpty ? nil : (InlineRun(content, .link), end + 1)
    }

    private static func emphasis(_ chars: [Character], _ start: Int) -> (InlineRun, Int)? {
        for (mark, count) in [("*", 2), ("_", 2), ("*", 1), ("_", 1)] {
            if let found = emphasis(chars, start, mark: Character(mark), count: count) { return found }
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
