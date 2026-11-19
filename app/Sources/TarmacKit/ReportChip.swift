import Foundation

/// What a terminal card's report chip shows. The copy places the report in
/// time only and never says who sent it; the edge pill and the inbox quote
/// its text.
public enum ReportChip {
    public struct Model: Equatable, Sendable {
        public let text: String
        /// The kind's signal, and so its colour; a dimmed chip keeps it on
        /// its border.
        public let signal: CardSignal
        public let dimmed: Bool
    }

    /// How often a shown chip reads its age again.
    public static let refreshInterval: TimeInterval = 30

    private static let title = "report"

    /// A report placed in time: `report · during <proc>`, or `report`. An
    /// inbox row and the preview pane read it.
    public static func heading(proc: String?) -> String {
        ChromeText.during(title, proc: proc)
    }

    public static func model(report: TermReport, nowMs: UInt64) -> Model {
        Model(
            text: "\(title) · \(ChromeText.reportAge(atMs: report.atMs, nowMs: nowMs))",
            signal: report.kind.signal,
            dimmed: report.read
        )
    }
}
