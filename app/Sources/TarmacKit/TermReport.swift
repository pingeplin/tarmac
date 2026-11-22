/// A terminal's current report, from a `term_report` frame (spec 2611.0009).
public struct TermReport: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case blocked
        case done

        /// The signal, and so the colour, of an unread report of this kind.
        public var signal: CardSignal {
            switch self {
            case .blocked: .blocked
            case .done: .done
            }
        }
    }

    public let kind: Kind
    public let text: String?
    public let atMs: UInt64
    public let proc: String?
    public let read: Bool
    /// The text as inline markdown, parsed once: a pill reads it on every
    /// viewport change (spec 2611.0017).
    public let quote: InlineText?

    public init(kind: Kind, text: String?, atMs: UInt64, proc: String?, read: Bool) {
        self.kind = kind
        self.text = text
        self.atMs = atMs
        self.proc = proc
        self.read = read
        quote = text.map(InlineMarkdown.line)
    }

    /// A `term_report` frame's terminal, its place and its report; nil for any other
    /// message. The report is nil for a frame that is no report: no `kind`, a
    /// kind this build does not know, or no `at_ms`.
    public static func frame(_ message: Message) -> TermReportFrame? {
        guard
            case .termReport(let termID, let kind, let text, let atMs, let proc, let read, let boardID, let cwd) =
                message
        else {
            return nil
        }
        let known: Kind?
        switch kind {
        case "blocked": known = .blocked
        case "done": known = .done
        default: known = nil
        }
        guard let known, let atMs else {
            return TermReportFrame(termID: termID, boardID: boardID, cwd: cwd, report: nil)
        }
        let report = TermReport(kind: known, text: text, atMs: atMs, proc: proc, read: read)
        return TermReportFrame(termID: termID, boardID: boardID, cwd: cwd, report: report)
    }
}

/// A `term_report` frame: the terminal, its place (2611.0013) and its report.
public struct TermReportFrame: Equatable, Sendable {
    public let termID: String
    public let boardID: String?
    public let cwd: String?
    public let report: TermReport?
}
