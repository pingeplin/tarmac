import Foundation

/// What a terminal card's report chip shows. The copy places the report in
/// time only; it never says who sent it, and quotes its text as a claim.
public enum ReportChip {
    public struct Model: Equatable, Sendable {
        public let text: String
        /// The kind's signal, and so its colour; a dimmed chip keeps it on
        /// its border.
        public let signal: CardSignal
        public let dimmed: Bool
        public let toolTip: String
    }

    /// How often a shown chip reads its age again.
    public static let refreshInterval: TimeInterval = 30

    private static let title = "report"

    /// A report placed in time: `report · during <proc>`, or `report`. The
    /// chip's tool tip and an inbox row both read it.
    public static func heading(proc: String?) -> String {
        ChromeText.during(title, proc: proc)
    }

    public static func model(report: TermReport, nowMs: UInt64) -> Model {
        let heading = heading(proc: report.proc)
        return Model(
            text: "\(title) · \(ChromeText.reportAge(atMs: report.atMs, nowMs: nowMs))",
            signal: report.kind.signal,
            dimmed: report.read,
            toolTip: report.text.map { "\(heading)\n“\($0)”" } ?? heading
        )
    }
}
