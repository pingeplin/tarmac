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
