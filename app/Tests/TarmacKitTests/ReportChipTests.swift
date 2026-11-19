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

    func testS7AnUnreadBlockedReportShowsItsAgeInItsKindsColour() throws {
        let chip = try model(frame())
        XCTAssertEqual(chip.text, "report · 2m")
        XCTAssertEqual(chip.signal, .blocked)
        XCTAssertFalse(chip.dimmed)
    }

    func testS7ADoneReportHasTheDoneToneAndAReadOneIsDimmed() throws {
        XCTAssertEqual(try model(frame(kind: "done")).signal, .done)
        let read = try model(frame(kind: "done", read: true))
        XCTAssertTrue(read.dimmed)
        XCTAssertEqual(read.signal, .done)
    }

    func testS19TheHeadingPlacesAReportInTimeAndNoProcIsTheBareTitle() {
        XCTAssertEqual(ReportChip.heading(proc: "claude"), "report · during claude")
        XCTAssertEqual(ReportChip.heading(proc: nil), "report")
    }

    /// #422: the chip has no tool tip; the text shows in the pill and the inbox.
    func testTheChipIsTheSameWithOrWithoutATextOrAProc() throws {
        XCTAssertEqual(try model(frame(text: nil, proc: nil)), try model(frame()))
    }

    func testS20AReportFromTheFutureIsUnderAMinuteOld() throws {
        XCTAssertEqual(try model(frame(atMs: now + 90_000)).text, "report · <1m")
    }
}
