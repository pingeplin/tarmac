import CoreGraphics
import XCTest
@testable import TarmacKit

/// HTML-card zoom geometry and the wheel's travel in a document's units:
/// specs 2607.0004 S10 (the settled real-px box), 2607.0006 (the frozen
/// magnification), 2609.0013 (whole-unit steps with a carry) and 2610.0002
/// (the wheel scale). Scenario ids are per spec and collide.
final class CardZoomTests: XCTestCase {
    // MARK: - magnifyK never upsamples (2607.0006)

    /// K ≥ the board's max zoom is what makes `scale(zoom/K)` a down-scale
    /// across the whole range; raising the max above K fails here.
    func testMagnifyKIsAtLeastTheBoardsMaxZoom() {
        XCTAssertGreaterThanOrEqual(CardZoom.magnifyK, BoardZoom.max)
        XCTAssertLessThanOrEqual(BoardZoom.max / CardZoom.magnifyK, 1)
    }

    /// The factor is part of what a card's document sees: the shim sets its
    /// root zoom to it, and its viewport is the card times it.
    func testTheFrozenMagnificationIsThree() {
        XCTAssertEqual(CardZoom.magnifyK, 3)
    }

    func testTheBoardZoomsFromATenthToThreeTimes() {
        XCTAssertEqual(BoardZoom.min, 0.1)
        XCTAssertEqual(BoardZoom.max, 3)
    }

    /// The web app's `RASTER_SCALE_SETTLE_MS`.
    func testAZoomHasSettledAfterAHundredAndFiftyMilliseconds() {
        XCTAssertEqual(CardZoom.settleDelay, 0.15)
    }

    // MARK: - iframePx (2607.0004 S10)

    func testIframePxIsTheFrameTimesZoomRounded() {
        XCTAssertEqual(CardZoom.iframePx(frame: CGSize(width: 640, height: 400), zoom: 1), CGSize(width: 640, height: 400))
        XCTAssertEqual(CardZoom.iframePx(frame: CGSize(width: 640, height: 400), zoom: 1.5), CGSize(width: 960, height: 600))
    }

    /// Rounds, not truncates — a truncation would give 100 for the first.
    func testIframePxRoundsNonIntegerProducts() {
        XCTAssertEqual(CardZoom.iframePx(frame: CGSize(width: 100, height: 100), zoom: 1.006), CGSize(width: 101, height: 101))
        XCTAssertEqual(CardZoom.iframePx(frame: CGSize(width: 100, height: 100), zoom: 0.994), CGSize(width: 99, height: 99))
    }

    // MARK: - wheelScale (2610.0002)

    /// One unit of a magnified document is `zoom / magnifyK` of a screen point.
    func test2610S1AMagnifiedDocumentTakesMagnifyKOverZoomUnitsAPoint() {
        XCTAssertEqual(CardZoom.wheelScale(zoom: 0.5, magnify: true), 6)
        XCTAssertEqual(CardZoom.wheelScale(zoom: 1, magnify: true), 3)
        XCTAssertEqual(CardZoom.wheelScale(zoom: 2, magnify: true), 1.5)
        XCTAssertEqual(CardZoom.wheelScale(zoom: 3, magnify: true), 1)
        XCTAssertEqual(CardZoom.wheelScale(zoom: 1.728, magnify: true), 3 / 1.728, accuracy: 1e-9)
    }

    func test2610S1ARevealDocumentTakesOneUnitAPoint() {
        XCTAssertEqual(CardZoom.wheelScale(zoom: 0.5, magnify: false), 1)
        XCTAssertEqual(CardZoom.wheelScale(zoom: 2, magnify: false), 1)
    }

    func test2610S14AZoomThatIsNoZoomScalesNothing() {
        for zoom in [0, -1, CGFloat.nan, .infinity] {
            XCTAssertEqual(CardZoom.wheelScale(zoom: zoom, magnify: true), 1, "\(zoom)")
        }
    }

    // MARK: - quantizeScrollDelta (2609.0013)

    func testS1PassesAWholeDeltaThroughUntouched() {
        XCTAssertEqual(CardZoom.quantizeScrollDelta(35, carry: 0), CardZoom.Quantized(step: 35, carry: 0))
        XCTAssertEqual(CardZoom.quantizeScrollDelta(0, carry: 0), CardZoom.Quantized(step: 0, carry: 0))
    }

    /// Ties are reachable (a 1 pt delta at zoom 2 is 1.5 units) and resolve
    /// as `Math.round` does, negative asymmetry included.
    func testResolvesTiesHalfUp() {
        XCTAssertEqual(CardZoom.quantizeScrollDelta(2.5, carry: 0).step, 3)
        XCTAssertEqual(CardZoom.quantizeScrollDelta(-2.5, carry: 0).step, -2)
    }

    func testS2EmitsAnIntegerStepWheneverTheTotalIsFractional() {
        XCTAssertEqual(CardZoom.quantizeScrollDelta(34.72, carry: 0).step, 35)
        XCTAssertEqual(CardZoom.quantizeScrollDelta(35, carry: 0.72).step, 36)
    }

    /// The no-drift claim: a carry-less implementation is off by ~0.28 px per
    /// event here and breaches 1 px by the fourth.
    func testS3KeepsEveryPrefixSumWithinOnePxOfExactTravel() {
        let d = 34.72
        var carry = 0.0
        var travelled = 0
        for n in 1...100 {
            let q = CardZoom.quantizeScrollDelta(d, carry: carry)
            travelled += q.step
            carry = q.carry
            XCTAssertLessThanOrEqual(abs(Double(travelled) - Double(n) * d), 1)
        }
        XCTAssertEqual(Double(travelled) + carry, 100 * d, accuracy: 1e-9)
    }

    func testS4AdvancesWithinBudgetOnSubPixelDeltas() {
        let d = 0.4
        let budget = Int((1 / d).rounded(.up)) + 1
        var carry = 0.0
        var travelled = 0
        for _ in 0..<budget {
            let q = CardZoom.quantizeScrollDelta(d, carry: carry)
            // Never backwards: a clamp forcing |step| ≥ 1 would jitter a slow drag.
            XCTAssertGreaterThanOrEqual(q.step, 0)
            travelled += q.step
            carry = q.carry
        }
        XCTAssertGreaterThanOrEqual(travelled, 1)
        let before = travelled
        for _ in 0..<budget {
            let q = CardZoom.quantizeScrollDelta(d, carry: carry)
            travelled += q.step
            carry = q.carry
        }
        XCTAssertGreaterThan(travelled, before)
    }

    /// The carry must be consumed, not merely stored: the small reverse delta
    /// only crosses a pixel because of the inherited residue.
    func testS5ConsumesTheCarryOnADirectionReversal() {
        let down = CardZoom.quantizeScrollDelta(34.72, carry: 0)
        XCTAssertEqual(CardZoom.quantizeScrollDelta(-0.3, carry: down.carry).step, -1)
        let back = CardZoom.quantizeScrollDelta(-34.72, carry: down.carry)
        XCTAssertEqual(down.step + back.step, 0)
    }

    func testS6PreservesDirectionForDeltasOfAtLeastOnePx() {
        for d in [-1.2, -34.72, -1000.5] {
            XCTAssertLessThan(CardZoom.quantizeScrollDelta(d, carry: 0).step, 0, "\(d)")
        }
    }

    func testS7CreatesAndDestroysNoTravel() {
        for d in [0, 12, 34.72, -34.72, 1234.567] {
            for c in [0, 0.42, -0.42] {
                let q = CardZoom.quantizeScrollDelta(d, carry: c)
                XCTAssertEqual(Double(q.step) + q.carry, d + c, accuracy: 1e-9)
            }
        }
    }

    /// Rules out satisfying S7 by parking whole pixels in the carry.
    func testS9NeverCarriesAWholePixel() {
        for d in [0, 12, 34.72, -34.72, 0.4, -0.4, 1234.567] {
            for c in [0, 0.99, -0.99] {
                XCTAssertLessThan(abs(CardZoom.quantizeScrollDelta(d, carry: c).carry), 1)
            }
        }
    }
}
