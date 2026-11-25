import TarmacKit
import XCTest

final class CardSignalTests: XCTestCase {
    func testTheNamesAreTheInboxTagsAndTheSnapshotValues() {
        XCTAssertEqual(
            [CardSignal.blocked, .bell, .exit, .done, .live].map(\.rawValue),
            ["blocked", "bell", "exit", "done", "live"]
        )
    }

    // MARK: - signal and rank (2611.0013 "Pill signal and fly target rank")

    private func report(_ kind: TermReport.Kind, read: Bool = false, text: String? = nil) -> TermReport {
        TermReport(kind: kind, text: text, atMs: 0, proc: nil, read: read)
    }

    private func signal(
        _ report: TermReport? = nil, bell: Bool = false, exit: Bool = false, live: Bool = true
    ) -> CardSignal? {
        CardSignal.of(report: report, bellLit: bell, exitUnread: exit, live: live)
    }

    /// "Pill signal and fly target rank".
    func testOnlyAnUnreadReportSignalsAndTheRestFallThroughInRank() {
        XCTAssertEqual(signal(report(.blocked), bell: true), .blocked)
        XCTAssertEqual(signal(report(.blocked, read: true), bell: true), .bell)
        XCTAssertEqual(signal(exit: true, live: false), .exit)
        XCTAssertEqual(signal(report(.done), exit: true, live: false), .exit)
        XCTAssertEqual(signal(report(.done)), .done)
        XCTAssertEqual(signal(report(.done, read: true)), .live)
        XCTAssertNil(signal(live: false))
    }

    /// "Pill signal and fly target rank".
    func testABellOutranksAnExitAndABlockedReportOutranksBoth() {
        XCTAssertEqual(signal(bell: true, exit: true, live: false), .bell)
        XCTAssertEqual(signal(report(.blocked), exit: true, live: false), .blocked)
    }

    /// "Pill signal and fly target rank".
    func testTheRankIsBlockedBellExitDoneLive() {
        let order: [CardSignal] = [.live, .done, .exit, .bell, .blocked]
        XCTAssertEqual(order.map(\.rank), [0, 1, 2, 3, 4])
    }
}
