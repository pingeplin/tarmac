import CoreGraphics
import XCTest
@testable import TarmacKit

/// An HTML card's wheel conversion (spec 2610.0002): what a wheel event's
/// delta becomes in the document's own units, and the residue a precise
/// device leaves for the next event.
final class CardWheelTests: XCTestCase {
    private func points(_ wheel: inout CardWheel, dx: Double = 0, dy: Double = 0, scale: CGFloat = 1.5) -> CardWheel.Delta? {
        wheel.convert(dx: dx, dy: dy, precise: true, scale: scale)
    }

    // MARK: - precise

    func testS2APreciseDeltaBecomesWholeDocumentUnits() {
        var down = CardWheel()
        XCTAssertEqual(points(&down, dy: -10), .points(dx: 0, dy: -15))

        var across = CardWheel()
        XCTAssertEqual(points(&across, dx: 4, scale: 3), .points(dx: 12, dy: 0))

        var both = CardWheel()
        XCTAssertEqual(points(&both, dx: 4, dy: -10), .points(dx: 6, dy: -15))

        var fractional = CardWheel()
        let scale = CardZoom.wheelScale(zoom: 1.728, magnify: true)
        XCTAssertEqual(points(&fractional, dy: -10, scale: scale), .points(dx: 0, dy: -17))
    }

    /// −1.5 a time: the tie goes up, to −1, and its half is owed to the next.
    func testS3TheCarryHoldsTravel() {
        var wheel = CardWheel()
        let answers = (0..<30).map { _ in points(&wheel, dy: -1) }
        let expected = (0..<30).map { CardWheel.Delta.points(dx: 0, dy: $0.isMultiple(of: 2) ? -1 : -2) }
        XCTAssertEqual(answers, expected)
    }

    /// 0.375 a time, and a tie at 0.5 on the fourth.
    func testS4ASlowDragIsNotLost() {
        var wheel = CardWheel()
        let answers = (0..<8).map { _ in points(&wheel, dy: 0.25) }
        XCTAssertEqual(answers, [0, 1, 0, 1, 0, 0, 1, 0].map { .points(dx: 0, dy: $0) })
    }

    // MARK: - notched

    func testS5ANotchedDeltaIsScaledAsLines() {
        var wheel = CardWheel()
        XCTAssertEqual(wheel.convert(dx: 0, dy: -1, precise: false, scale: 1.5), .lines(dx: 0, dy: -1.5))
        XCTAssertEqual(wheel.convert(dx: 2, dy: 0, precise: false, scale: 3), .lines(dx: 6, dy: 0))
    }

    // MARK: - pass-through

    func testS15NothingIsConvertedAtAScaleOfOneOrOneThatIsNoScale() {
        for scale in [1, 0, -2, CGFloat.nan, .infinity] {
            for precise in [true, false] {
                var wheel = CardWheel()
                XCTAssertNil(wheel.convert(dx: 3, dy: -7, precise: precise, scale: scale), "\(scale) \(precise)")
            }
        }
    }

    /// 1.25 is chosen so that a pass-through which added to the residue (2),
    /// quantized into it (0) or cleared it (0) would each answer otherwise,
    /// and the axes go opposite ways so that one's residue is not the other's.
    func testS15APassThroughLeavesTheResidueAsItWas() {
        var wheel = CardWheel()
        XCTAssertEqual(points(&wheel, dx: 0.25, dy: -0.25), .points(dx: 0, dy: 0))
        XCTAssertNil(points(&wheel, dx: 1.25, dy: -1.25, scale: 1))
        XCTAssertEqual(points(&wheel, dx: 0.25, dy: -0.25), .points(dx: 1, dy: -1))
    }

    /// The event is still passed on: its phase is content.
    func testS16AZeroStepIsAnAnswer() {
        var small = CardWheel()
        XCTAssertEqual(points(&small, dy: 0.25), .points(dx: 0, dy: 0))

        var still = CardWheel()
        XCTAssertEqual(points(&still), .points(dx: 0, dy: 0))
    }

    // MARK: - residue

    func testS17TheAxesDoNotShareResidue() {
        var wheel = CardWheel()
        XCTAssertEqual(points(&wheel, dx: 0.25), .points(dx: 0, dy: 0))
        XCTAssertEqual(points(&wheel, dy: 0.25), .points(dx: 0, dy: 0))
        XCTAssertEqual(points(&wheel, dx: 0.25), .points(dx: 1, dy: 0))
    }

    func testS18ANotchedEventNeitherReadsNorWritesTheResidue() {
        var wheel = CardWheel()
        XCTAssertEqual(points(&wheel, dx: 0.25, dy: -0.25), .points(dx: 0, dy: 0))
        XCTAssertEqual(wheel.convert(dx: 1, dy: -1, precise: false, scale: 1.5), .lines(dx: 1.5, dy: -1.5))
        XCTAssertEqual(points(&wheel, dx: 0.25, dy: -0.25), .points(dx: 1, dy: -1))
    }

    func testS19EachWheelKeepsItsOwnResidue() {
        var first = CardWheel()
        var second = CardWheel()
        XCTAssertEqual(points(&first, dy: 0.25), .points(dx: 0, dy: 0))
        XCTAssertEqual(points(&second, dy: 0.25), .points(dx: 0, dy: 0))
        XCTAssertEqual(points(&first, dy: 0.25), .points(dx: 0, dy: 1))
    }

    func testS20NoTravelIsMadeOrLost() {
        var wheel = CardWheel()
        let deltas = [0.25, 0.25, -0.75, 2.5, -0.25, 0.25, 1.5, -3.75]
        var steps: [Int] = []
        var travelled = 0.0
        for delta in deltas {
            guard case .points(_, let dy) = points(&wheel, dy: delta) else { return XCTFail("\(delta) was not converted") }
            steps.append(dy)
            travelled += delta
            XCTAssertLessThanOrEqual(abs(Double(steps.reduce(0, +)) - 1.5 * travelled), 0.5, "after \(delta)")
        }
        XCTAssertEqual(steps, [0, 1, -1, 3, 0, 0, 3, -6])
    }
}
