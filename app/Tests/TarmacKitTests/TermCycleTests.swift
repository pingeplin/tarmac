import XCTest
@testable import TarmacKit

/// Cycling the prime terminal: order (live only, spawn order) and the wrapping step.
final class TermCycleTests: XCTestCase {
    private func term(_ id: String, live: Bool = true) -> TermCycle.Term {
        TermCycle.Term(termID: id, isLive: live)
    }

    // MARK: - order

    func testOrderDropsDeadTermsAndKeepsSpawnOrder() {
        XCTAssertEqual(TermCycle.order([term("a"), term("b", live: false), term("c")]), ["a", "c"])
    }

    func testOrderKeepsEveryIDWhenAllAreLive() {
        XCTAssertEqual(TermCycle.order([term("x"), term("y")]), ["x", "y"])
    }

    func testOrderIsEmptyWhenAllTermsAreDead() {
        XCTAssertEqual(TermCycle.order([term("a", live: false), term("b", live: false)]), [])
    }

    func testOrderIsEmptyForNoTerms() {
        XCTAssertEqual(TermCycle.order([]), [])
    }

    // MARK: - step

    func testStepOverNoTermsIsNil() {
        XCTAssertNil(TermCycle.step(order: [], from: "a", .next))
        XCTAssertNil(TermCycle.step(order: [], from: "a", .prev))
    }

    func testStepWithASingleLiveTermReturnsItBothWays() {
        XCTAssertEqual(TermCycle.step(order: ["a"], from: "a", .next), "a")
        XCTAssertEqual(TermCycle.step(order: ["a"], from: "a", .prev), "a")
    }

    func testStepFromNoCurrentTermLandsOnTheFirstForNextAndTheLastForPrev() {
        XCTAssertEqual(TermCycle.step(order: ["a", "b", "c"], from: nil, .next), "a")
        XCTAssertEqual(TermCycle.step(order: ["a", "b", "c"], from: nil, .prev), "c")
    }

    func testStepFromACurrentTermOutsideTheOrderLandsOnTheFirstForNextAndTheLastForPrev() {
        XCTAssertEqual(TermCycle.step(order: ["a", "b", "c"], from: "z", .next), "a")
        XCTAssertEqual(TermCycle.step(order: ["a", "b", "c"], from: "z", .prev), "c")
    }

    func testStepWrapsFromLastToFirstOnNext() {
        XCTAssertEqual(TermCycle.step(order: ["a", "b", "c"], from: "c", .next), "a")
    }

    func testStepWrapsFromFirstToLastOnPrev() {
        XCTAssertEqual(TermCycle.step(order: ["a", "b", "c"], from: "a", .prev), "c")
    }

    func testStepMovesForwardFromTheMiddleOnNext() {
        XCTAssertEqual(TermCycle.step(order: ["a", "b", "c"], from: "a", .next), "b")
    }

    func testStepMovesBackwardFromTheMiddleOnPrev() {
        XCTAssertEqual(TermCycle.step(order: ["a", "b", "c"], from: "c", .prev), "b")
    }

    // MARK: - cycle

    func testCycleSkipsADeadTermAndLandsOnTheNextLiveOne() {
        let terms = [term("a"), term("b", live: false), term("c")]
        XCTAssertEqual(TermCycle.cycle(terms, from: "a", .next), "c")
    }

    func testCycleWrapsFromTheLastLiveToTheFirstLive() {
        let terms = [term("a"), term("b", live: false), term("c")]
        XCTAssertEqual(TermCycle.cycle(terms, from: "c", .next), "a")
    }

    func testCycleIsNilWhenNoTermIsLive() {
        XCTAssertNil(TermCycle.cycle([term("a", live: false), term("b", live: false)], from: "a", .next))
    }
}
