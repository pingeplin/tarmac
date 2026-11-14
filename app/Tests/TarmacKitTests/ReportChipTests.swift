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

    // S7
    func testS7AnUnreadBlockedReportQuotesItsTextAndPlacesItInTime() throws {
        let chip = try model(frame())
        XCTAssertEqual(chip.text, "回報 · 2m")
        XCTAssertEqual(chip.tone, .blocked)
        XCTAssertFalse(chip.dimmed)
        XCTAssertEqual(chip.toolTip, "回報 · 在 claude 期間\n「May I?」")
    }

    // S7
    func testS7ADoneReportHasTheDoneToneAndAReadOneIsDimmed() throws {
        XCTAssertEqual(try model(frame(kind: "done")).tone, .done)
        let read = try model(frame(kind: "done", read: true))
        XCTAssertTrue(read.dimmed)
        XCTAssertEqual(read.tone, .done)
    }

    // S19
    func testS19NoProcIsTheBareTitleAndNoTextIsOneLine() throws {
        XCTAssertEqual(try model(frame(proc: nil)).toolTip, "回報\n「May I?」")
        XCTAssertEqual(try model(frame(text: nil)).toolTip, "回報 · 在 claude 期間")
        XCTAssertEqual(try model(frame(text: nil, proc: nil)).toolTip, "回報")
    }

    // S19
    func testS19AFrameWithNoKindAnUnknownKindOrNoAtMsIsNoReportForItsTerminal() {
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

    // S20
    func testS20AReportFromTheFutureIsUnderAMinuteOld() throws {
        XCTAssertEqual(try model(frame(atMs: now + 90_000)).text, "回報 · <1m")
    }
}
