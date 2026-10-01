import XCTest
@testable import TarmacKit

/// The reconnect half of `applyRestore` in `desktop/src/App.tsx`.
final class ReconnectRestoreTests: XCTestCase {
    private typealias Term = ReconnectRestore.Term

    private func reconcile(
        _ terms: [Term], live: Set<String>, replayFollows: Bool = false
    ) -> ReconnectRestore.Outcome {
        ReconnectRestore.reconcile(terms, liveTerms: live, replayFollows: replayFollows)
    }

    func testTerminalsTheDaemonStillOwnsAreLeftAlone() {
        let outcome = reconcile([Term(termID: "a", pty: .live), Term(termID: "b", pty: .live)], live: ["a", "b"])
        XCTAssertEqual(outcome.lost, [])
        XCTAssertFalse(outcome.daemonRestarted)
    }

    func testATerminalTheDaemonNoLongerOwnsIsLost() {
        let outcome = reconcile(
            [Term(termID: "a", pty: .live), Term(termID: "b", pty: .live), Term(termID: "c", pty: .live)],
            live: ["b"]
        )
        XCTAssertEqual(outcome.lost, ["a", "c"])
        XCTAssertFalse(outcome.daemonRestarted, "one survivor means the daemon did not restart")
    }

    func testAnEmptyLiveListForABoardThatHadALiveTerminalIsADaemonRestart() {
        let outcome = reconcile([Term(termID: "a", pty: .live), Term(termID: "b", pty: .dead)], live: [])
        XCTAssertEqual(outcome.lost, ["a"])
        XCTAssertTrue(outcome.daemonRestarted)
    }

    func testAnEmptyLiveListForABoardWithNothingLiveIsNotARestart() {
        let outcome = reconcile([Term(termID: "a", pty: .dead), Term(termID: "b", pty: .unspawned)], live: [])
        XCTAssertEqual(outcome.lost, [])
        XCTAssertFalse(outcome.daemonRestarted)
    }

    /// A card whose spawn has not been sent has lost nothing: it still spawns.
    func testATerminalThatNeverSpawnedIsNotLost() {
        let outcome = reconcile([Term(termID: "a", pty: .live), Term(termID: "b", pty: .unspawned)], live: ["a"])
        XCTAssertEqual(outcome.lost, [])
    }

    func testADeadTerminalIsNotLostTwice() {
        XCTAssertEqual(reconcile([Term(termID: "a", pty: .dead)], live: ["b"]).lost, [])
    }

    // MARK: - replayed history

    /// The first restore of a board on a connection is followed by each live
    /// terminal's whole ring, which a card that already shows it must not append.
    func testSurvivorsAreReplayedWhenAReplayFollows() {
        let outcome = reconcile(
            [
                Term(termID: "a", pty: .live), Term(termID: "b", pty: .live),
                Term(termID: "c", pty: .dead), Term(termID: "d", pty: .unspawned),
            ],
            live: ["a", "c", "d"], replayFollows: true
        )
        XCTAssertEqual(outcome.replayed, ["a"])
        XCTAssertEqual(outcome.lost, ["b"])
    }

    func testNothingIsReplayedOnALaterRestoreOfTheSameConnection() {
        let outcome = reconcile([Term(termID: "a", pty: .live)], live: ["a"], replayFollows: false)
        XCTAssertEqual(outcome.replayed, [])
    }

    // MARK: - restart

    func testARestartLosesEveryLiveTerminalOnEveryOtherBoard() {
        XCTAssertEqual(
            ReconnectRestore.lostToRestart([
                Term(termID: "a", pty: .live), Term(termID: "b", pty: .dead),
                Term(termID: "c", pty: .unspawned), Term(termID: "d", pty: .live),
            ]),
            ["a", "d"]
        )
    }

    func testTheRestartToastNamesTheWayForward() {
        XCTAssertEqual(ReconnectRestore.restartToastTitle, "daemon restarted — terminals lost")
        XCTAssertEqual(ReconnectRestore.restartToastBody, "open new terminals with ⌘T")
    }
}
