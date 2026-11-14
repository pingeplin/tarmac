import Foundation

/// A terminal's current report, from a `term_report` frame (spec 2611.0009).
public struct TermReport: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case blocked
        case done
    }

    public let kind: Kind
    public let text: String?
    public let atMs: UInt64
    public let proc: String?
    public let read: Bool

    public init(kind: Kind, text: String?, atMs: UInt64, proc: String?, read: Bool) {
        self.kind = kind
        self.text = text
        self.atMs = atMs
        self.proc = proc
        self.read = read
    }

    /// A `term_report` frame's terminal and its report; nil for any other
    /// message. The report is nil for a frame that is no report: no `kind`, a
    /// kind this build does not know, or no `at_ms`.
    public static func frame(_ message: Message) -> (termID: String, report: TermReport?)? {
        guard case .termReport(let termID, let kind, let text, let atMs, let proc, let read) = message else {
            return nil
        }
        let known: Kind?
        switch kind {
        case "blocked": known = .blocked
        case "done": known = .done
        default: known = nil
        }
        guard let known, let atMs else { return (termID, nil) }
        return (termID, TermReport(kind: known, text: text, atMs: atMs, proc: proc, read: read))
    }
}

/// What a terminal card's report chip shows. The copy places the report in
/// time only; it never says who sent it, and quotes its text as a claim.
public enum ReportChip {
    public struct Model: Equatable, Sendable {
        public let text: String
        /// The kind's colour; a dimmed chip keeps it on its border.
        public let tone: TermReport.Kind
        public let dimmed: Bool
        public let toolTip: String
    }

    /// How often a shown chip reads its age again.
    public static let refreshInterval: TimeInterval = 30

    private static let title = "report"

    public static func model(report: TermReport, nowMs: UInt64) -> Model {
        let elapsed = nowMs >= report.atMs ? nowMs - report.atMs : 0
        let heading = report.proc.map { "\(title) · during \($0)" } ?? title
        return Model(
            text: "\(title) · \(ChromeText.reportAge(elapsedMs: elapsed))",
            tone: report.kind,
            dimmed: report.read,
            toolTip: report.text.map { "\(heading)\n“\($0)”" } ?? heading
        )
    }
}
