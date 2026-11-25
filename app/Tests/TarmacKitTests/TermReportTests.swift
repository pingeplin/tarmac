import TarmacKit
import XCTest

/// Spec 2611.0009: a `term_report` frame, and the report it gives.
final class TermReportTests: XCTestCase {
    private let now: UInt64 = 1_800_000_000_000

    private func frame(
        kind: String? = "blocked",
        text: String? = "May I?",
        atMs: UInt64? = 1_800_000_000_000 - 125_000,
        proc: String? = "claude",
        read: Bool = false
    ) -> Message {
        .termReport(termID: "t1", kind: kind, text: text, atMs: atMs, proc: proc, read: read)
    }

    /// "Chip copy without proc or text".
    func testAFrameWithNoKindAnUnknownKindOrNoAtMsIsNoReportForItsTerminal() {
        for message in [frame(kind: nil), frame(kind: "later"), frame(atMs: nil)] {
            let parsed = TermReport.frame(message)
            XCTAssertEqual(parsed?.termID, "t1")
            XCTAssertNil(parsed?.report)
        }
        XCTAssertNil(TermReport.frame(.bell(termID: "t1")))
    }

    func testAFrameKeepsItsFields() {
        let parsed = TermReport.frame(frame(read: true))
        XCTAssertEqual(parsed?.termID, "t1")
        XCTAssertEqual(
            parsed?.report,
            TermReport(kind: .blocked, text: "May I?", atMs: now - 125_000, proc: "claude", read: true)
        )
    }

    /// 2611.0017: the text is parsed once, when the report comes, not on
    /// every pill refresh.
    func testAReportKeepsItsTextParsedAsInlineMarkdown() {
        let report = TermReport(kind: .blocked, text: "**May** I?", atMs: 0, proc: nil, read: false)
        XCTAssertEqual(report.quote, InlineMarkdown.line("**May** I?"))
        XCTAssertNil(TermReport(kind: .done, text: nil, atMs: 0, proc: nil, read: false).quote)
    }

    // 2611.0013: the frame gives the report's place too.
    func testAFrameGivesItsBoardAndFolder() {
        let message = Message.termReport(
            termID: "t1", kind: "done", text: nil, atMs: 5, proc: nil, read: false, boardID: "board-1", cwd: "/w"
        )
        let parsed = TermReport.frame(message)
        XCTAssertEqual(parsed?.boardID, "board-1")
        XCTAssertEqual(parsed?.cwd, "/w")
        XCTAssertNil(TermReport.frame(frame())?.boardID)
    }
}
