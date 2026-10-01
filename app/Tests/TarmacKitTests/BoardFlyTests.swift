import XCTest
@testable import TarmacKit

/// A fly is a 300 ms ease-in-out of zoom and center together.
final class BoardFlyTests: XCTestCase {
    private let fly = BoardFly(
        from: BoardViewport(zoom: 0.5, cx: 0, cy: 100),
        to: BoardViewport(zoom: 1.5, cx: 400, cy: -100)
    )

    func testAFlyLastsThreeHundredMilliseconds() {
        XCTAssertEqual(BoardFly.durationMs, 300)
    }

    func testTheEaseStartsAndEndsAtRestAndIsSymmetric() {
        XCTAssertEqual(BoardFly.easeInOutQuad(0), 0)
        XCTAssertEqual(BoardFly.easeInOutQuad(1), 1)
        XCTAssertEqual(BoardFly.easeInOutQuad(0.5), 0.5)
        XCTAssertEqual(BoardFly.easeInOutQuad(0.25), 0.125)
        XCTAssertEqual(BoardFly.easeInOutQuad(0.75), 0.875)
    }

    func testItStartsAtTheOrigin() {
        XCTAssertEqual(fly.viewport(atElapsedMs: 0), fly.from)
    }

    func testAQuarterOfTheWayThroughItHasCoveredAnEighth() {
        XCTAssertEqual(fly.viewport(atElapsedMs: 75), BoardViewport(zoom: 0.625, cx: 50, cy: 75))
    }

    func testHalfwayThroughItIsHalfwayThere() {
        XCTAssertEqual(fly.viewport(atElapsedMs: 150), BoardViewport(zoom: 1, cx: 200, cy: 0))
    }

    func testItLandsExactlyOnTheTarget() {
        XCTAssertEqual(fly.viewport(atElapsedMs: 300), fly.to)
    }

    /// A late frame must not overshoot or drift off the target.
    func testPastTheEndItStaysOnTheTarget() {
        XCTAssertEqual(fly.viewport(atElapsedMs: 900), fly.to)
    }

    func testBeforeTheStartItStaysAtTheOrigin() {
        XCTAssertEqual(fly.viewport(atElapsedMs: -16), fly.from)
    }

    func testItIsFinishedOnlyOnceTheFullDurationHasElapsed() {
        XCTAssertFalse(fly.isFinished(atElapsedMs: 0))
        XCTAssertFalse(fly.isFinished(atElapsedMs: 299.9))
        XCTAssertTrue(fly.isFinished(atElapsedMs: 300))
        XCTAssertTrue(fly.isFinished(atElapsedMs: 450))
    }
}
