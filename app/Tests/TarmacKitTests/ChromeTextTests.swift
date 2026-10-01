import XCTest
@testable import TarmacKit

/// The small chrome formatters: zoom readout, titlebar chip fallback, recency meta.
final class ChromeTextTests: XCTestCase {
    func testZoomPercentRoundsToWholePercentHalfUp() {
        XCTAssertEqual(ChromeText.zoomPercent(1), "100%")
        XCTAssertEqual(ChromeText.zoomPercent(0.125), "13%", "12.5 is an exact half, rounded up")
        XCTAssertEqual(ChromeText.zoomPercent(0.1), "10%")
        XCTAssertEqual(ChromeText.zoomPercent(3), "300%")
    }

    /// `Math.round` sends a negative half up, toward zero — where `rounded()` would
    /// send it away.
    func testZoomPercentRoundsANegativeHalfTowardPositiveInfinityLikeMathRound() {
        XCTAssertEqual(ChromeText.zoomPercent(-0.125), "-12%")
        XCTAssertEqual(ChromeText.zoomPercent(-0.126), "-13%")
        XCTAssertEqual(ChromeText.zoomPercent(-0.001), "0%", "Math.round(-0.1) is -0, which reads 0")
    }

    func testZoomPercentOfNonFiniteOrHugeInputReadsLikeTheDesktopAppAndDoesNotTrap() {
        XCTAssertEqual(ChromeText.zoomPercent(.nan), "NaN%")
        XCTAssertEqual(ChromeText.zoomPercent(.infinity), "Infinity%")
        XCTAssertEqual(ChromeText.zoomPercent(-.infinity), "-Infinity%")
        XCTAssertEqual(ChromeText.zoomPercent(1e17), "10000000000000000000%")
        XCTAssertEqual(ChromeText.zoomPercent(1e300), "1e+302%")
    }

    func testBoardChipLabelUsesTheNameWhenPresent() {
        XCTAssertEqual(ChromeText.boardChipLabel(name: "Frontend", boardID: "b-1"), "Frontend")
    }

    func testBoardChipLabelFallsBackToTheIDForANilOrEmptyName() {
        XCTAssertEqual(ChromeText.boardChipLabel(name: nil, boardID: "b-1"), "b-1")
        XCTAssertEqual(ChromeText.boardChipLabel(name: "", boardID: "b-3"), "b-3")
    }

    func testRecencyLabelIsNilWithoutAChangeTime() {
        XCTAssertNil(ChromeText.recencyLabel(lastChangedMs: nil, nowMs: 1000))
    }

    func testRecencyLabelIsWholeSecondsFlooredAtOneWithinTheWindow() {
        XCTAssertEqual(ChromeText.recencyLabel(lastChangedMs: 1000, nowMs: 1000), "✎ 1s")
        XCTAssertEqual(ChromeText.recencyLabel(lastChangedMs: 1000, nowMs: 1500), "✎ 1s")
        XCTAssertEqual(ChromeText.recencyLabel(lastChangedMs: 1000, nowMs: 2600), "✎ 2s")
    }

    func testRecencyLabelIsNilAtAndAfterTheThirtySecondBoundary() {
        XCTAssertNil(ChromeText.recencyLabel(lastChangedMs: 1000, nowMs: 1000 + ChromeText.recentWindowMs))
        XCTAssertEqual(
            ChromeText.recencyLabel(lastChangedMs: 1000, nowMs: 1000 + ChromeText.recentWindowMs - 1),
            "✎ 30s"
        )
    }

    /// A future-dated change time (mtime/clock skew) counts as recent, like
    /// `DocStore.isRecent`, and clamps the elapsed time to zero.
    func testRecencyLabelTreatsAFutureChangeTimeAsRecent() {
        XCTAssertEqual(ChromeText.recencyLabel(lastChangedMs: 2000, nowMs: 1000), "✎ 1s")
    }

    @MainActor
    func testTheRecencyGateAgreesWithDocStore() {
        XCTAssertEqual(ChromeText.recentWindowMs, DocStore.recentWindowMs)
        for nowMs: UInt64 in [500, 1000, 1500, 30_999, 31_000, 31_001, 60_000] {
            XCTAssertEqual(
                ChromeText.recencyLabel(lastChangedMs: 1000, nowMs: nowMs) != nil,
                DocStore.isRecent(lastChangedMs: 1000, nowMs: nowMs),
                "nowMs \(nowMs)"
            )
        }
    }
}
