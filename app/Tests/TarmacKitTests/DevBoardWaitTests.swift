import XCTest
@testable import TarmacKit

/// `tarmac dev board`: when the wait answers. A switch changes `activeBoardID`
/// at once and `switching` stays true until the board is mounted, so only
/// both together mean the snapshot would show the board.
final class DevBoardWaitTests: XCTestCase {
    private typealias Step = DevSnapshotWait.Step

    private func landed(_ id: String) -> Step {
        .reply(DevReply(ok: true, body: #"{"board_id":"\#(id)"}"#))
    }

    func testTheAnswerNamesTheBoardThatIsActive() {
        XCTAssertEqual(DevBoardWait.reply(boardID: "board-1"), DevReply(ok: true, body: #"{"board_id":"board-1"}"#))
    }

    func testASwitchLandsOnlyOnceTheBoardIsActiveAndMounted() {
        let wait = DevBoardWait(goal: .board("board-1"))
        XCTAssertEqual(wait.step(activeBoardID: "board-0", switching: false, elapsedMs: 0), .pollAgain)
        XCTAssertEqual(wait.step(activeBoardID: "board-1", switching: true, elapsedMs: 10), .pollAgain)
        XCTAssertEqual(wait.step(activeBoardID: "board-1", switching: false, elapsedMs: 20), landed("board-1"))
    }

    func testAnActiveBoardAnswersAtOnce() {
        let wait = DevBoardWait(goal: .board("board-0"))
        XCTAssertEqual(wait.step(activeBoardID: "board-0", switching: false, elapsedMs: 0), landed("board-0"))
    }

    /// Before the daemon's `board_list` the active board is still the old one,
    /// and that must not read as done.
    func testACreateLandsOnTheNewBoardNotBeforeItIsMounted() {
        let wait = DevBoardWait(goal: .otherThan("board-0"))
        XCTAssertEqual(wait.step(activeBoardID: "board-0", switching: false, elapsedMs: 0), .pollAgain)
        XCTAssertEqual(wait.step(activeBoardID: "board-2", switching: true, elapsedMs: 10), .pollAgain)
        XCTAssertEqual(wait.step(activeBoardID: "board-2", switching: false, elapsedMs: 20), landed("board-2"))
    }

    func testAWaitThatNeverLandsEndsInATimeoutNamingTheActiveBoard() {
        let wait = DevBoardWait(goal: .board("board-1"), timeoutMs: 300)
        XCTAssertEqual(wait.step(activeBoardID: "board-0", switching: false, elapsedMs: 299), .pollAgain)
        let error = DevError(
            .timeout, "board `board-1` was not active within 300ms",
            extra: ["board_id": "board-0", "timeout_ms": 300, "switching": false]
        )
        XCTAssertEqual(wait.step(activeBoardID: "board-0", switching: false, elapsedMs: 300), .reply(error.reply))
    }

    func testACreateThatNeverLandsEndsInATimeoutToo() {
        let wait = DevBoardWait(goal: .otherThan("board-0"), timeoutMs: 300)
        let error = DevError(
            .timeout, "no new board was active within 300ms",
            extra: ["board_id": "board-0", "timeout_ms": 300, "switching": true]
        )
        XCTAssertEqual(wait.step(activeBoardID: "board-0", switching: true, elapsedMs: 300), .reply(error.reply))
    }

    func testTheLandingIsCheckedBeforeTheDeadline() {
        let wait = DevBoardWait(goal: .board("board-1"), timeoutMs: 300)
        XCTAssertEqual(wait.step(activeBoardID: "board-1", switching: false, elapsedMs: 300), landed("board-1"))
    }

    func testTheDefaultBudgetIsTheProtocolsBoardWait() {
        XCTAssertEqual(DevBoardWait(goal: .board("x")).timeoutMs, 5_000)
    }
}
