import XCTest
@testable import TarmacKit

/// `tarmac dev snapshot --until <expr> --timeout <ms>` (spec 2609.0015, #166;
/// parity row Q13): when a wait answers, and with what. `snapshotReply` in
/// `desktop/src/devDriver.ts` is the loop this is one turn of.
final class DevSnapshotWaitTests: XCTestCase {
    private typealias Step = DevSnapshotWait.Step

    private let half: JSONValue = ["v": 1, "viewport": ["zoom": 0.5]]
    private let whole: JSONValue = ["v": 1, "viewport": ["zoom": 1]]

    private func ok(_ snapshot: JSONValue) -> Step {
        .reply(DevReply(ok: true, body: snapshot.jsonString))
    }

    private func timeout(_ expression: String, _ timeoutMs: Int, _ snapshot: JSONValue) -> Step {
        .reply(DevError.timeout(expression: expression, timeoutMs: timeoutMs, snapshot: snapshot).reply)
    }

    func testWithNoExpressionTheSnapshotIsTheReply() throws {
        let wait = try DevSnapshotWait(until: nil, timeoutMs: 5_000)
        XCTAssertEqual(wait.step(snapshot: half, elapsedMs: 0), ok(half))
    }

    func testAnExpressionThatHoldsAnswersWithTheSnapshotItHeldOn() throws {
        let wait = try DevSnapshotWait(until: "viewport.zoom == 1", timeoutMs: 5_000)
        XCTAssertEqual(wait.step(snapshot: half, elapsedMs: 0), .pollAgain)
        XCTAssertEqual(wait.step(snapshot: half, elapsedMs: 4_999), .pollAgain)
        XCTAssertEqual(wait.step(snapshot: whole, elapsedMs: 50), ok(whole))
    }

    /// `smoke.mjs` D9(b) reads `error`, `timeout_ms` and the final snapshot.
    func testPastTheBudgetTheWaitFailsWithTheLastSnapshot() throws {
        let wait = try DevSnapshotWait(until: "viewport.zoom == 99", timeoutMs: 300)
        XCTAssertEqual(wait.step(snapshot: half, elapsedMs: 299), .pollAgain)
        XCTAssertEqual(wait.step(snapshot: half, elapsedMs: 300), timeout("viewport.zoom == 99", 300, half))
        XCTAssertEqual(wait.step(snapshot: whole, elapsedMs: 350), timeout("viewport.zoom == 99", 300, whole))
    }

    /// `--timeout 0` means evaluate once, so the check precedes the first wait.
    func testAZeroBudgetEvaluatesOnce() throws {
        let wait = try DevSnapshotWait(until: "viewport.zoom == 1", timeoutMs: 0)
        XCTAssertEqual(wait.step(snapshot: whole, elapsedMs: 0), ok(whole))
        XCTAssertEqual(wait.step(snapshot: half, elapsedMs: 0), timeout("viewport.zoom == 1", 0, half))
    }

    func testAnExpressionThatHoldsOnTheLastLookStillAnswers() throws {
        let wait = try DevSnapshotWait(until: "viewport.zoom == 1", timeoutMs: 300)
        XCTAssertEqual(wait.step(snapshot: whole, elapsedMs: 900), ok(whole))
    }

    func testAnUnstatedBudgetIsFiveSeconds() throws {
        let wait = try DevSnapshotWait(until: "viewport.zoom == 1", timeoutMs: nil)
        XCTAssertEqual(wait.step(snapshot: half, elapsedMs: 4_999), .pollAgain)
        XCTAssertEqual(wait.step(snapshot: half, elapsedMs: 5_000), timeout("viewport.zoom == 1", 5_000, half))
    }

    /// An expression that can never hold must not spend the budget pretending
    /// it might.
    func testAMalformedExpressionIsRefusedBeforeAnyWait() {
        XCTAssertThrowsError(try DevSnapshotWait(until: "viewport.zoom", timeoutMs: 5_000)) { error in
            let refusal = error as? DevError
            XCTAssertEqual(refusal?.code, .badExpr)
            XCTAssertEqual(refusal?.extra, ["expr": "viewport.zoom"])
        }
    }

    func testTheSnapshotIsReReadEveryFiftyMilliseconds() {
        XCTAssertEqual(DevSnapshotWait.pollMs, 50)
    }
}
