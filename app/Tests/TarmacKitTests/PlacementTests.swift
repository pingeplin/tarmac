import CoreGraphics
import XCTest
@testable import TarmacKit

/// Where a `tarmac open` doc lands on the board: a first-free-slot grid search
/// beside the owning terminal, and the M1 scatter fallback.
final class PlacementTests: XCTestCase {
    private let owner = Placement.termFrame

    private var anchorX: CGFloat { owner.maxX + Placement.gapX }

    // MARK: - rectsIntersect

    func testRectsIntersectIsTrueForOverlapAndFalseForTouchingEdges() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertTrue(Placement.rectsIntersect(a, CGRect(x: 5, y: 5, width: 10, height: 10)))
        XCTAssertFalse(Placement.rectsIntersect(a, CGRect(x: 10, y: 0, width: 10, height: 10)), "shared edge only")
        XCTAssertFalse(Placement.rectsIntersect(a, CGRect(x: 20, y: 0, width: 10, height: 10)))
    }

    /// `CGRect.intersects` calls two coincident zero-size rects intersecting; the
    /// half-open overlap rule does not, and a zero-area cull rect depends on it.
    func testRectsIntersectIsStrictForZeroSizeRects() {
        let point = CGRect(x: 5, y: 5, width: 0, height: 0)
        XCTAssertFalse(Placement.rectsIntersect(point, point))
        XCTAssertTrue(Placement.rectsIntersect(point, CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertFalse(Placement.rectsIntersect(CGRect(x: 10, y: 5, width: 0, height: 0), CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    // MARK: - firstFreeSlot

    func testFirstDocLandsAtTheAnchorRightOfTheOwnerAtItsTop() {
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: owner, existing: []),
            CGRect(x: 80 + 470 + 86, y: 80, width: 392, height: 310)
        )
    }

    func testSkipsToTheNextColumnWhenTheAnchorSlotIsOccupied() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let second = Placement.firstFreeSlot(owner: owner, existing: [first])
        XCTAssertEqual(
            second,
            CGRect(x: first.minX + Placement.docWidth + Placement.gapX, y: first.minY,
                   width: Placement.docWidth, height: Placement.docHeight)
        )
        XCTAssertFalse(Placement.rectsIntersect(first, second))
    }

    func testAnExistingCardWithinTheCollisionInsetStillCountsAsOccupied() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let near = first.offsetBy(dx: 4, dy: 0)
        XCTAssertNotEqual(Placement.firstFreeSlot(owner: owner, existing: [near]).minX, first.minX)
    }

    func testWrapsToTheNextRowWhenARowFillsUp() {
        let rowBlockers = (0..<Placement.scanCols).map { col in
            CGRect(x: anchorX + CGFloat(col) * (Placement.docWidth + Placement.gapX), y: owner.minY,
                   width: Placement.docWidth, height: Placement.docHeight)
        }
        let placed = Placement.firstFreeSlot(owner: owner, existing: rowBlockers)
        XCTAssertEqual(placed.minY, owner.minY + Placement.docHeight + Placement.gapY)
        XCTAssertEqual(placed.minX, anchorX)
    }

    func testStacksAtTheAnchorWhenTheWholeScanGridIsOccupied() {
        let everything = CGRect(x: -1e6, y: -1e6, width: 2e7, height: 2e7)
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: owner, existing: [everything]),
            CGRect(x: anchorX, y: owner.minY, width: Placement.docWidth, height: Placement.docHeight)
        )
    }

    // MARK: - scatterFrame

    func testScatterFillsATwoColumnGridRightOfTheTerminal() {
        let baseX = Placement.termFrame.maxX + Placement.gapX
        XCTAssertEqual(Placement.scatterFrame(slot: 0), CGRect(x: 636, y: 80, width: 392, height: 310))
        let s1 = Placement.scatterFrame(slot: 1)
        XCTAssertEqual(s1.minX, baseX + Placement.docWidth + Placement.gapX, "slot 1 is column 1 of the same row")
        XCTAssertEqual(s1.minY, Placement.termFrame.minY)
        let s2 = Placement.scatterFrame(slot: 2)
        XCTAssertEqual(s2.minX, baseX, "slot 2 is column 0 of row 1")
        XCTAssertEqual(s2.minY, Placement.termFrame.minY + Placement.docHeight + Placement.gapY)
    }

    func testTheLayoutConstantsMatchTheDocumentedGrid() {
        XCTAssertEqual(Placement.termFrame, CGRect(x: 80, y: 80, width: 470, height: 330))
        XCTAssertEqual(Placement.docWidth, 392)
        XCTAssertEqual(Placement.docHeight, 310)
        XCTAssertEqual(Placement.gapX, 86)
        XCTAssertEqual(Placement.gapY, 40)
        XCTAssertEqual(Placement.cascadeDX, 43)
        XCTAssertEqual(Placement.cascadeDY, 40)
        XCTAssertEqual(Placement.collisionInset, 8)
        XCTAssertEqual(Placement.scanRows, 64)
        XCTAssertEqual(Placement.scanCols, 64)
        XCTAssertEqual(Placement.docColumns, 2)
    }

    // MARK: - the collision inset and the scan extent

    /// The neighbour starts 4 pt past the first slot's right edge, so only the 8 pt
    /// inset makes it collide: with no inset, or one that shrinks, the slot is free.
    func testACardJustPastTheSlotsRightEdgeStillCollidesThroughTheInset() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let neighbour = CGRect(x: first.maxX + 4, y: first.minY, width: 100, height: Placement.docHeight)
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: owner, existing: [neighbour]),
            CGRect(x: anchorX + 2 * (Placement.docWidth + Placement.gapX), y: owner.minY,
                   width: Placement.docWidth, height: Placement.docHeight),
            "columns 0 and 1 are both within 8 pt of the neighbour"
        )
    }

    func testACardJustBelowTheSlotStillCollidesThroughTheInset() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let below = CGRect(x: first.minX, y: first.maxY + 4, width: Placement.docWidth, height: 20)
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: owner, existing: [below]),
            CGRect(x: anchorX + Placement.docWidth + Placement.gapX, y: owner.minY,
                   width: Placement.docWidth, height: Placement.docHeight)
        )
    }

    func testACardMoreThanTheInsetAwayDoesNotCollide() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let clear = CGRect(x: first.maxX + 9, y: first.minY, width: 20, height: Placement.docHeight)
        XCTAssertEqual(Placement.firstFreeSlot(owner: owner, existing: [clear]), first)
    }

    /// Columns 0…62 blocked in every row: the slot is column 63 of row 0, which a
    /// scan of only 63 columns would never reach.
    func testTheScanReachesTheSixtyFourthColumn() {
        let pitch = Placement.docWidth + Placement.gapX
        let blocked = CGRect(x: 0, y: -1e6, width: anchorX + 62 * pitch + Placement.docWidth, height: 2e6)
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: owner, existing: [blocked]),
            CGRect(x: anchorX + 63 * pitch, y: owner.minY, width: Placement.docWidth, height: Placement.docHeight)
        )
    }

    /// Rows 0…62 blocked in every column: the slot is row 63, column 0.
    func testTheScanReachesTheSixtyFourthRow() {
        let pitch = Placement.docHeight + Placement.gapY
        let blocked = CGRect(x: -1e6, y: 0, width: 2e6, height: owner.minY + 62 * pitch + Placement.docHeight)
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: owner, existing: [blocked]),
            CGRect(x: anchorX, y: owner.minY + 63 * pitch, width: Placement.docWidth, height: Placement.docHeight)
        )
    }
}
