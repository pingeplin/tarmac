import XCTest

@testable import TarmacKit

/// Spec 2609.0017 (#172): the first-visit notice after a version-mismatch
/// restart. Every expected string is pasted from the spec's Interface Contract.
final class RestartNoticeTests: XCTestCase {
    private let replaced = RestartNotice.Replacement(from: "0.12.2", to: "0.12.3")

    private func notice(
        _ replaced: RestartNotice.Replacement?,
        _ tileTermIDs: [String?],
        live: Set<String> = [],
        alreadyNotified: Bool = false
    ) -> RestartNotice? {
        RestartNotice.make(
            replaced: replaced,
            tileTermIDs: tileTermIDs,
            liveTerms: live,
            alreadyNotified: alreadyNotified
        )
    }

    /// "Restart notice names versions and lost count".
    func testNamesBothVersionsAndCountsTheLostTerminals() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2"]),
            RestartNotice(
                title: "tarmacd restarted: 0.12.2 → 0.12.3",
                body: "2 terminals on this board were restarted"
            )
        )
    }

    /// "Restart notice names versions and lost count".
    func testThePluralCountLeavesOutTerminalsThatCameBackLive() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2", "t3"], live: ["t1"])?.body,
            "2 terminals on this board were restarted"
        )
    }

    /// "Restart notice names versions and lost count".
    func testThePluralBodyCarriesTheLostCountNotAFixedNumber() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2", "t3", "t4"], live: ["t1"])?.body,
            "3 terminals on this board were restarted"
        )
    }

    /// "Cold start without replaced shows no notice".
    func testAColdStartWithNoReplacedDaemonGetsNoNotice() {
        XCTAssertNil(notice(nil, ["t1"]))
    }

    /// "Tile without terminal id shows no notice".
    func testAFreshBoardWhoseTileHasNoPersistedIDGetsNoNotice() {
        XCTAssertNil(notice(replaced, [nil]))
    }

    /// "Still live terminals show no notice".
    func testTerminalsThatCameBackLiveGetNoNotice() {
        XCTAssertNil(notice(replaced, ["t1", "t2"], live: ["t1", "t2"]))
    }

    /// "Notice counts only lost terminals".
    func testCountsOnlyPersistedIDsThatAreNotLiveInTheSingularForOne() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2", nil], live: ["t1"])?.body,
            "1 terminal on this board was restarted"
        )
    }

    /// "Notice counts only lost terminals".
    func testLiveIDsFromOtherBoardsDoNotReduceTheCountAndNilTilesNeverCount() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2", nil, nil], live: ["t9"])?.body,
            "2 terminals on this board were restarted"
        )
    }

    /// "Unknown old version reads as unknown".
    func testAReplacedDaemonThatReportedNoVersionReadsAsUnknown() {
        let replaced = RestartNotice.Replacement(from: nil, to: "0.12.3")
        XCTAssertEqual(notice(replaced, ["t1"])?.title, "tarmacd restarted: unknown → 0.12.3")
    }

    /// "Unknown new version reads as unknown".
    func testARespawnedDaemonThatReportedNoVersionReadsAsUnknown() {
        let replaced = RestartNotice.Replacement(from: "0.12.2", to: nil)
        XCTAssertEqual(notice(replaced, ["t1"])?.title, "tarmacd restarted: 0.12.2 → unknown")
    }

    /// "Already notified shows no notice".
    func testARestartAlreadyNotifiedGetsNoSecondNotice() {
        XCTAssertNil(notice(replaced, ["t1", "t2"], alreadyNotified: true))
    }

    /// "Board with no tiles shows no notice".
    func testABoardWithNoTerminalTilesGetsNoNotice() {
        XCTAssertNil(notice(replaced, []))
    }

    /// The count is per tile, not per distinct id: two tiles carrying the same lost
    /// id are two lost terminals.
    func testEachTileWithALostIDCountsEvenWhenTheIDRepeats() {
        XCTAssertEqual(notice(replaced, ["t1", "t1"])?.body, "2 terminals on this board were restarted")
    }
}
