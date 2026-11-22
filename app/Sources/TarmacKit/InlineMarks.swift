/// The inline marks of one line of source (spec 2611.0017 D3).
enum InlineMarks {
    /// `source` as runs, its whitespace settled.
    static func text(_ source: some StringProtocol) -> InlineText {
        InlineText(runs(source)).settled
    }

    private static func runs(_ text: some StringProtocol) -> [InlineRun] {
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
                // A run of backticks that opens no span is literal as a whole:
                // a span never starts inside it.
                let next = index + max(backticks(chars, index), 1)
                plain.append(contentsOf: chars[index..<next])
                index = next
            }
        }
        runs.append(InlineRun(plain, .plain))
        return runs
    }

    /// A run of backticks, the content, and the next run of the same length.
    private static func code(_ chars: [Character], _ start: Int) -> (InlineRun, Int)? {
        let length = backticks(chars, start)
        guard length > 0 else { return nil }
        let open = start + length
        var at = open
        while let close = chars[at...].firstIndex(of: "`") {
            let closing = backticks(chars, close)
            if closing == length { return span(chars[open..<close], .code, next: close + length) }
            at = close + closing
        }
        return nil
    }

    private static func backticks(_ chars: [Character], _ start: Int) -> Int {
        chars[start...].prefix { $0 == "`" }.count
    }

    private static func link(_ chars: [Character], _ start: Int) -> (InlineRun, Int)? {
        guard chars[start] == "[", let close = chars[(start + 1)...].firstIndex(of: "]"),
            close + 1 < chars.count, chars[close + 1] == "(",
            let end = chars[(close + 2)...].firstIndex(of: ")")
        else { return nil }
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
        guard
            let close = (open..<chars.count).first(where: {
                isMark($0) && !(underscore && insideWord(chars, neighbour: $0 + count, away: 1))
            })
        else { return nil }
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
}

// MARK: - Whitespace (D4)

extension InlineText {
    /// Each run of whitespace is one space, and the text has none at its ends.
    var settled: InlineText {
        var runs = self.runs.map { InlineRun(Self.collapsed($0.text), $0.mark) }
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
