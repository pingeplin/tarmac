import CoreGraphics
import XCTest
@testable import TarmacKit

/// Where a QA-driver press may land on a target (spec 2609.0015, #166; parity
/// row Q21): the points the app hit-tests, in the order it tries them.
final class DevTargetPointsTests: XCTestCase {
    private let rect = CGRect(x: 100, y: 40, width: 600, height: 360)

    func testTheMiddleIsTriedFirst() {
        XCTAssertEqual(DevTargetPoints.candidates(in: rect).first, CGPoint(x: 400, y: 220))
    }

    /// The middle of the board is where a card usually is, and the middle of a
    /// card may be under another: the rest of the rect is walked cell by cell.
    func testTheRestIsAGridOfCellCentresRowByRow() {
        let grid = Array(DevTargetPoints.candidates(in: rect).dropFirst())
        XCTAssertEqual(grid.count, 36)
        XCTAssertEqual(grid.first, CGPoint(x: 150, y: 70))
        XCTAssertEqual(grid[1], CGPoint(x: 250, y: 70))
        XCTAssertEqual(grid[6], CGPoint(x: 150, y: 130))
        XCTAssertEqual(grid.last, CGPoint(x: 650, y: 370))
    }

    func testEveryPointIsStrictlyInsideTheRect() {
        for point in DevTargetPoints.candidates(in: rect) {
            XCTAssertTrue(rect.insetBy(dx: 1, dy: 1).contains(point), "\(point)")
        }
    }

    func testAnEmptyRectHasNoPoints() {
        XCTAssertEqual(DevTargetPoints.candidates(in: .zero), [])
        XCTAssertEqual(DevTargetPoints.candidates(in: CGRect(x: 5, y: 5, width: 0, height: 40)), [])
    }
}
