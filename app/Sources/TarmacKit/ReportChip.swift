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

    /// Nil for any other message, and for a frame that is no report: no
    /// `kind`, a kind this build does not know, or no `at_ms`.
    public static func from(_ message: Message) -> TermReport? {
        guard case .termReport(_, let kind, let text, let atMs, let proc, let read) = message,
              let atMs else { return nil }
        let known: Kind
        switch kind {
        case "blocked": known = .blocked
        case "done": known = .done
        default: return nil
        }
        return TermReport(kind: known, text: text, atMs: atMs, proc: proc, read: read)
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

    private static let title = "回報"

    public static func model(report: TermReport, nowMs: UInt64) -> Model {
        let elapsed = nowMs >= report.atMs ? nowMs - report.atMs : 0
        let heading = report.proc.map { "\(title) · 在 \($0) 期間" } ?? title
        return Model(
            text: "\(title) · \(age(elapsedMs: elapsed))",
            tone: report.kind,
            dimmed: report.read,
            toolTip: report.text.map { "\(heading)\n「\($0)」" } ?? heading
        )
    }

    /// `<1m`, `Nm`, `Nh` or `Nd`, each floored.
    public static func age(elapsedMs: UInt64) -> String {
        let minutes = elapsedMs / 60_000
        switch minutes {
        case 0: return "<1m"
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }
}
