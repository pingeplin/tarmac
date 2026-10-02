import CoreGraphics
import XCTest
@testable import TarmacKit

/// HTML-card zoom geometry and the shielded-card wheel relay: specs 2607.0004
/// S10 (the settled real-px box), 2607.0006 (the frozen magnification) and
/// 2609.0013 (whole-px relayed scroll deltas).
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

    // MARK: - scrollDelta

    func testScrollDeltaDividesByZoomOnlyInMagnify() {
        XCTAssertEqual(CardZoom.scrollDelta(60, zoom: 2, magnify: true), 30)
        XCTAssertEqual(CardZoom.scrollDelta(60, zoom: 2, magnify: false), 60)
        XCTAssertEqual(CardZoom.scrollDelta(60, zoom: 0, magnify: true), 60)
    }

    // MARK: - wheelDelta

    /// AppKit's scrolling delta has the opposite sign to a web wheel event's,
    /// and a notched wheel reports lines.
    func testAWheelEventsDeltaIsItsScrollingDeltaNegated() {
        XCTAssertEqual(CardZoom.wheelDelta(scrollingDelta: 12.5, precise: true), -12.5)
        XCTAssertEqual(CardZoom.wheelDelta(scrollingDelta: -3, precise: true), 3)
    }

    func testANotchedWheelsLinesAreScaledUp() {
        XCTAssertEqual(CardZoom.wheelDelta(scrollingDelta: 1, precise: false), -10)
        XCTAssertEqual(CardZoom.wheelDelta(scrollingDelta: -2, precise: false), 20)
    }

    // MARK: - quantizeScrollDelta (2609.0013)

    func testS1PassesAWholeDeltaThroughUntouched() {
        XCTAssertEqual(CardZoom.quantizeScrollDelta(35, carry: 0), CardZoom.Quantized(step: 35, carry: 0))
        XCTAssertEqual(CardZoom.quantizeScrollDelta(0, carry: 0), CardZoom.Quantized(step: 0, carry: 0))
    }

    /// Ties are reachable (zoom 2.0, a 35 px notch → 17.5) and resolve as
    /// `Math.round` does, negative asymmetry included.
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

    // MARK: - ScrollRelay (2609.0013 S11–S15)

    func testS12StillPostsWhenOnlyOneAxisQuantizesToZero() {
        var a = CardZoom.ScrollRelay()
        XCTAssertNotNil(a.step(dx: 0.2, dy: 34.72))
        var b = CardZoom.ScrollRelay()
        XCTAssertNotNil(b.step(dx: 34.72, dy: 0.2))
    }

    func testS14KeepsEachAxisOnItsOwnDelta() {
        var relay = CardZoom.ScrollRelay()
        XCTAssertEqual(relay.step(dx: 30.4, dy: -12.6), CardZoom.ScrollStep(dx: 30, dy: -13))
    }

    /// Both carries are written back even when nothing is posted, or a slow
    /// drag never accumulates (S11, S13, S15).
    func testS15AccumulatesAcrossSuppressedPostsUntilItCrossesAPixel() {
        var relay = CardZoom.ScrollRelay()
        XCTAssertNil(relay.step(dx: 0.2, dy: 0.3))
        XCTAssertEqual(relay.step(dx: 0.2, dy: 0.3), CardZoom.ScrollStep(dx: 0, dy: 1))
        XCTAssertEqual(relay.step(dx: 0.2, dy: 0), CardZoom.ScrollStep(dx: 1, dy: 0))
    }

    /// S11: each axis carries its own residue. Sideways travel left over from
    /// one event is not downward travel in the next.
    func testS11TheResidueOfOneAxisIsNotTheOthers() {
        var relay = CardZoom.ScrollRelay()
        XCTAssertNil(relay.step(dx: 0.4, dy: 0))
        XCTAssertNil(relay.step(dx: 0, dy: 0.3))
        XCTAssertEqual(relay.step(dx: 0.2, dy: 0.2), CardZoom.ScrollStep(dx: 1, dy: 1))
    }

    func testEachRelayKeepsItsOwnCarry() {
        var a = CardZoom.ScrollRelay()
        var b = CardZoom.ScrollRelay()
        let first = a.step(dx: 0, dy: 0.6)
        _ = a.step(dx: 0, dy: 0.6)
        _ = a.step(dx: 0, dy: 0.6)
        XCTAssertEqual(b.step(dx: 0, dy: 0.6), first)
    }

    /// At a non-integer board zoom the unit conversion alone yields a fraction,
    /// and the relay must absorb it.
    func testARealWheelNotchBecomesWholeDocumentPxAtZoom1728() {
        let delta = CardZoom.scrollDelta(60, zoom: 1.728, magnify: true)
        XCTAssertNotEqual(delta, delta.rounded())
        var relay = CardZoom.ScrollRelay()
        XCTAssertEqual(relay.step(dx: 0, dy: delta), CardZoom.ScrollStep(dx: 0, dy: 35))
    }
}
