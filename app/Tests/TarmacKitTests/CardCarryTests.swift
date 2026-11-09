import CoreGraphics
import XCTest
@testable import TarmacKit

/// A terminal's attached docs travel with it while it is moved or resized, and
/// with no other card. Each doc follows the terminal edge it faces.
final class CardCarryTests: XCTestCase {
    private let ownerFrame = CGRect(x: 100, y: 100, width: 470, height: 330)
    private let size = CGSize(width: 392, height: 310)

    private func at(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: x, y: y), size: size) }

    /// One doc on each side and each corner of the owner, 86 / 40 off its edges.
    private var ring: [String: CGRect] {
        [
            "right": at(656, 100), "below": at(100, 470), "left": at(-378, 100), "above": at(100, -250),
            "belowRight": at(656, 470), "aboveLeft": at(-378, -250),
        ]
    }

    private func carry(_ satellites: [String: CGRect]) -> CardCarry<String> {
        CardCarry(owner: "term", ownerFrame: ownerFrame, satellites: satellites)
    }

    // MARK: - Move

    func testTheSatellitesFollowTheirOwnerByItsTravel() {
        XCTAssertEqual(
            carry(["a": at(600, 100), "b": at(600, 450)]).origins(moving: "term", to: ownerFrame.offsetBy(dx: 30, dy: -40)),
            ["a": CGPoint(x: 630, y: 60), "b": CGPoint(x: 630, y: 410)]
        )
    }

    /// A move shifts both edges alike, so a doc between them follows too.
    func testAMoveCarriesEveryDocWhereverItSits() {
        let moved = carry(ring).origins(moving: "term", to: ownerFrame.offsetBy(dx: 30, dy: -40))
        XCTAssertEqual(moved, ring.mapValues { CGPoint(x: $0.minX + 30, y: $0.minY - 40) })
    }

    /// Each step is measured from where the owner was pressed, so the
    /// satellites retrace the owner's path instead of accumulating its steps.
    func testTheTravelIsMeasuredFromThePressNotFromTheLastStep() {
        let c = carry(["a": at(600, 100)])
        _ = c.origins(moving: "term", to: ownerFrame.offsetBy(dx: 200, dy: 200))
        XCTAssertEqual(c.origins(moving: "term", to: ownerFrame), ["a": CGPoint(x: 600, y: 100)])
    }

    func testAnotherCardsMoveCarriesNothing() {
        let c = carry(["a": at(600, 100)])
        XCTAssertEqual(c.origins(moving: "other", to: ownerFrame.offsetBy(dx: 30, dy: 0)), [:])
        XCTAssertEqual(c.origins(moving: "a", to: CGRect.zero), [:])
    }

    func testAnOwnerWithNoSatellitesCarriesNothing() {
        XCTAssertEqual(carry([:]).origins(moving: "term", to: ownerFrame.offsetBy(dx: 50, dy: 50)), [:])
    }

    // MARK: - Resize

    /// The bottom-right handle moves the right and bottom edges only.
    func testABottomRightGrowMovesTheDocsThatFaceTheRightAndBottomEdges() {
        let grown = CGRect(x: 100, y: 100, width: 720, height: 460)
        XCTAssertEqual(carry(ring).origins(moving: "term", to: grown), [
            "right": CGPoint(x: 906, y: 100), "below": CGPoint(x: 100, y: 600),
            "left": CGPoint(x: -378, y: 100), "above": CGPoint(x: 100, y: -250),
            "belowRight": CGPoint(x: 906, y: 600), "aboveLeft": CGPoint(x: -378, y: -250),
        ])
    }

    /// The top-left handle moves the left and top edges only; a doc below the
    /// owner sits between its left and right edges and stays.
    func testATopLeftGrowMovesTheDocsThatFaceTheLeftAndTopEdges() {
        let grown = CGRect(x: 50, y: 60, width: 520, height: 370)
        XCTAssertEqual(carry(ring).origins(moving: "term", to: grown), [
            "right": CGPoint(x: 656, y: 100), "below": CGPoint(x: 100, y: 470),
            "left": CGPoint(x: -428, y: 100), "above": CGPoint(x: 100, y: -290),
            "belowRight": CGPoint(x: 656, y: 470), "aboveLeft": CGPoint(x: -428, y: -290),
        ])
    }

    /// A shrink pulls the docs in: every gap to a moved edge is the gap at the press.
    func testAShrinkKeepsTheGapToEveryMovedEdge() {
        let shrunk = CGRect(x: 100, y: 100, width: 300, height: 200)
        let moved = carry(ring).origins(moving: "term", to: shrunk)
        XCTAssertEqual(moved["right"]!.x - shrunk.maxX, ring["right"]!.minX - ownerFrame.maxX)
        XCTAssertEqual(moved["below"]!.y - shrunk.maxY, ring["below"]!.minY - ownerFrame.maxY)
        XCTAssertEqual(moved["belowRight"], CGPoint(x: 656 - 170, y: 470 - 130))
    }

    /// A doc that overlaps the owner on an axis has no edge to face on it.
    func testADocOverlappingTheOwnerStaysOnThatAxisDuringAResize() {
        let overlapping = ["o": CGRect(x: 400, y: 300, width: 392, height: 310)]
        let grown = CGRect(x: 100, y: 100, width: 720, height: 460)
        XCTAssertEqual(carry(overlapping).origins(moving: "term", to: grown), ["o": CGPoint(x: 400, y: 300)])
    }
}
