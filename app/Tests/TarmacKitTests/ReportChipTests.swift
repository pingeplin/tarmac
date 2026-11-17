import XCTest
import TarmacKit

/// Spec 2611.0009: what a terminal card's report chip shows.
final class ReportChipTests: XCTestCase {
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

    private func model(_ message: Message) throws -> ReportChip.Model {
        ReportChip.model(report: try XCTUnwrap(TermReport.frame(message)?.report), nowMs: now)
    }

    func testS7AnUnreadBlockedReportQuotesItsTextAndPlacesItInTime() throws {
        let chip = try model(frame())
        XCTAssertEqual(chip.text, "report · 2m")
        XCTAssertEqual(chip.signal, .blocked)
        XCTAssertFalse(chip.dimmed)
        XCTAssertEqual(chip.toolTip, "report · during claude\n“May I?”")
    }

    func testS7ADoneReportHasTheDoneToneAndAReadOneIsDimmed() throws {
        XCTAssertEqual(try model(frame(kind: "done")).signal, .done)
        let read = try model(frame(kind: "done", read: true))
        XCTAssertTrue(read.dimmed)
        XCTAssertEqual(read.signal, .done)
    }

    func testS19NoProcIsTheBareTitleAndNoTextIsOneLine() throws {
        XCTAssertEqual(try model(frame(proc: nil)).toolTip, "report\n“May I?”")
        XCTAssertEqual(try model(frame(text: nil)).toolTip, "report · during claude")
        XCTAssertEqual(try model(frame(text: nil, proc: nil)).toolTip, "report")
    }

    func testS20AReportFromTheFutureIsUnderAMinuteOld() throws {
        XCTAssertEqual(try model(frame(atMs: now + 90_000)).text, "report · <1m")
    }
}
