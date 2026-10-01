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

    func testS1NamesBothVersionsAndCountsTheLostTerminals() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2"]),
            RestartNotice(
                title: "tarmacd restarted: 0.12.2 → 0.12.3",
                body: "2 terminals on this board were restarted"
            )
        )
    }

    func testS1ThePluralCountLeavesOutTerminalsThatCameBackLive() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2", "t3"], live: ["t1"])?.body,
            "2 terminals on this board were restarted"
        )
    }

    func testS1ThePluralBodyCarriesTheLostCountNotAFixedNumber() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2", "t3", "t4"], live: ["t1"])?.body,
            "3 terminals on this board were restarted"
        )
    }

    func testS3AColdStartWithNoReplacedDaemonGetsNoNotice() {
        XCTAssertNil(notice(nil, ["t1"]))
    }

    func testS4AFreshBoardWhoseTileHasNoPersistedIDGetsNoNotice() {
        XCTAssertNil(notice(replaced, [nil]))
    }

    func testS5TerminalsThatCameBackLiveGetNoNotice() {
        XCTAssertNil(notice(replaced, ["t1", "t2"], live: ["t1", "t2"]))
    }

    func testS6CountsOnlyPersistedIDsThatAreNotLiveInTheSingularForOne() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2", nil], live: ["t1"])?.body,
            "1 terminal on this board was restarted"
        )
    }

    func testS6LiveIDsFromOtherBoardsDoNotReduceTheCountAndNilTilesNeverCount() {
        XCTAssertEqual(
            notice(replaced, ["t1", "t2", nil, nil], live: ["t9"])?.body,
            "2 terminals on this board were restarted"
        )
    }

    func testS7AReplacedDaemonThatReportedNoVersionReadsAsUnknown() {
        let replaced = RestartNotice.Replacement(from: nil, to: "0.12.3")
        XCTAssertEqual(notice(replaced, ["t1"])?.title, "tarmacd restarted: unknown → 0.12.3")
    }

    func testS7bARespawnedDaemonThatReportedNoVersionReadsAsUnknown() {
        let replaced = RestartNotice.Replacement(from: "0.12.2", to: nil)
        XCTAssertEqual(notice(replaced, ["t1"])?.title, "tarmacd restarted: 0.12.2 → unknown")
    }

    func testS8ARestartAlreadyNotifiedGetsNoSecondNotice() {
        XCTAssertNil(notice(replaced, ["t1", "t2"], alreadyNotified: true))
    }

    func testS9ABoardWithNoTerminalTilesGetsNoNotice() {
        XCTAssertNil(notice(replaced, []))
    }
}
