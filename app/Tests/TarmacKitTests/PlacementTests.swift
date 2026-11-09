import CoreGraphics
import XCTest
@testable import TarmacKit

/// Where a `tarmac open` doc lands on the board: the first free slot in the
/// rings around the owning terminal, and the M1 scatter fallback.
final class PlacementTests: XCTestCase {
    private let owner = Placement.termFrame

    // MARK: - openingViewport

    /// A board nobody has moved shows its boot terminal at 100 %, in the middle
    /// of the board whatever the window's size.
    func testTheOpeningViewportCentresTheBootTerminalAtFullZoom() {
        let opening = Placement.openingViewport
        XCTAssertEqual(opening.zoom, 1)
        for board in [CGSize(width: 1100, height: 650), CGSize(width: 2200, height: 1300)] {
            let middle = CGPoint(x: board.width / 2, y: board.height / 2)
            let onScreen = BoardTransform.worldToView(
                CGPoint(x: owner.midX, y: owner.midY),
                zoom: opening.zoom, center: CGPoint(x: opening.cx, y: opening.cy), viewportCenter: middle
            )
            XCTAssertEqual(onScreen, middle, "board \(board)")
        }
    }

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

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: Placement.docWidth, height: Placement.docHeight)
    }

    /// `count` docs opened one after another from `terminal`, each placed with
    /// the terminal and every earlier doc on the board.
    private func place(_ count: Int, around terminal: CGRect) -> [CGRect] {
        (0..<count).reduce(into: []) { placed, _ in
            placed.append(Placement.firstFreeSlot(owner: terminal, existing: [terminal] + placed))
        }
    }

    private let bigTerminal = CGRect(x: 80, y: 80, width: 720, height: 460)

    func testFirstDocLandsAtTheAnchorRightOfTheOwnerAtItsTop() {
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: owner, existing: []),
            CGRect(x: 80 + 470 + 86, y: 80, width: 392, height: 310)
        )
        XCTAssertEqual(place(1, around: owner), [doc(636, 80)])
    }

    /// The boot terminal has room for one doc on each side: right, below, left,
    /// above, then the corners clockwise from bottom-right.
    func testDocsCircleTheBootTerminalClockwiseSidesThenCorners() {
        XCTAssertEqual(place(8, around: owner), [
            doc(636, 80), doc(80, 450), doc(-398, 80), doc(80, -270),
            doc(636, 450), doc(-398, 450), doc(-398, -270), doc(636, -270),
        ])
    }

    /// A 720×460 terminal has room for two docs along each side, so a side's
    /// second slot comes before any corner. The right side's second slot hangs
    /// into the bottom row and takes the bottom's second slot; a corner that a
    /// side slot covers is skipped too. Only top-left is left, then ring two.
    func testABigTerminalTakesItsSecondSideSlotsBeforeTheCorners() {
        XCTAssertEqual(place(9, around: bigTerminal), [
            doc(886, 80), doc(80, 580), doc(-398, 80), doc(80, -270),
            doc(886, 430), doc(-398, 430), doc(558, -270),
            doc(-398, -270), doc(1364, -270),
        ])
    }

    /// A full first ring sends the next doc to the second ring: the ring around
    /// the terminal grown by one pitch, starting right of it at its top.
    func testTheNinthDocAroundTheBootTerminalOpensTheSecondRing() {
        XCTAssertEqual(place(9, around: owner).last, doc(1114, -270))
    }

    /// #232 acceptance: six docs lie on at least three sides of their terminal,
    /// and none is farther from it than one doc plus the gap.
    func testSixDocsSurroundTheirTerminalWithinOneDocAndAGap() {
        for terminal in [owner, bigTerminal] {
            let docs = place(6, around: terminal)
            let reach = terminal.insetBy(
                dx: -(Placement.docWidth + Placement.gapX), dy: -(Placement.docHeight + Placement.gapY)
            )
            for d in docs { XCTAssertTrue(reach.contains(d), "\(d) around \(terminal)") }
            let sides = Set(docs.flatMap { d -> [String] in
                [d.minX >= terminal.maxX ? "right" : nil, d.maxX <= terminal.minX ? "left" : nil,
                 d.minY >= terminal.maxY ? "below" : nil, d.maxY <= terminal.minY ? "above" : nil]
                    .compactMap { $0 }
            })
            XCTAssertGreaterThanOrEqual(sides.count, 3, "\(sides) around \(terminal)")
        }
    }

    func testNoPlacedDocComesWithinTheInsetOfAnEarlierCard() {
        for terminal in [owner, bigTerminal] {
            let docs = place(40, around: terminal)
            for (i, d) in docs.enumerated() {
                for other in [terminal] + docs[..<i] {
                    let grown = other.insetBy(dx: -Placement.collisionInset, dy: -Placement.collisionInset)
                    XCTAssertFalse(Placement.rectsIntersect(d, grown), "doc \(i) \(d) vs \(other)")
                }
            }
        }
    }

    /// The slot takes the size it is given, and that size sets how many slots
    /// fit along each side.
    func testASlotTakesTheSizeItIsGiven() {
        let size = Placement.termFrame.size
        let first = Placement.firstFreeSlot(owner: bigTerminal, existing: [bigTerminal], size: size)
        XCTAssertEqual(first, CGRect(origin: CGPoint(x: 886, y: 80), size: size))
        var taken = [bigTerminal, first]
        for _ in 0..<3 { taken.append(Placement.firstFreeSlot(owner: bigTerminal, existing: taken, size: size)) }
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: bigTerminal, existing: taken, size: size).origin,
            CGPoint(x: 886, y: 450), "the right side's second slot, one terminal height plus the gap down"
        )
    }

    func testAnExistingCardWithinTheCollisionInsetStillCountsAsOccupied() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let near = first.offsetBy(dx: 4, dy: 0)
        XCTAssertNotEqual(Placement.firstFreeSlot(owner: owner, existing: [near]), first)
    }

    func testStacksAtTheFirstSlotWhenEveryRingIsOccupied() {
        let everything = CGRect(x: -1e6, y: -1e6, width: 2e7, height: 2e7)
        XCTAssertEqual(Placement.firstFreeSlot(owner: owner, existing: [everything]), doc(636, 80))
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
        XCTAssertEqual(Placement.ringCount, 16)
        XCTAssertEqual(Placement.docColumns, 2)
    }

    // MARK: - the collision inset and the scan extent

    /// The neighbour starts 4 pt past the first slot's right edge, so only the 8 pt
    /// inset makes it collide: with no inset, or one that shrinks, the slot is free.
    func testACardJustPastTheSlotsRightEdgeStillCollidesThroughTheInset() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let neighbour = CGRect(x: first.maxX + 4, y: first.minY, width: 100, height: Placement.docHeight)
        XCTAssertEqual(Placement.firstFreeSlot(owner: owner, existing: [neighbour]), doc(80, 450))
    }

    func testACardJustBelowTheSlotStillCollidesThroughTheInset() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let below = CGRect(x: first.minX, y: first.maxY + 4, width: Placement.docWidth, height: 20)
        XCTAssertEqual(Placement.firstFreeSlot(owner: owner, existing: [below]), doc(80, 450))
    }

    func testACardMoreThanTheInsetAwayDoesNotCollide() {
        let first = Placement.firstFreeSlot(owner: owner, existing: [])
        let clear = CGRect(x: first.maxX + 9, y: first.minY, width: 20, height: Placement.docHeight)
        XCTAssertEqual(Placement.firstFreeSlot(owner: owner, existing: [clear]), first)
    }

    /// Every ring before the last blocked: the slot is the first of the last
    /// ring, which a scan of one ring fewer never reaches.
    func testTheScanReachesTheLastRing() {
        let inner = CGFloat(Placement.ringCount - 1)
        let blocked = owner.insetBy(
            dx: -inner * (Placement.docWidth + Placement.gapX), dy: -inner * (Placement.docHeight + Placement.gapY)
        )
        XCTAssertEqual(
            Placement.firstFreeSlot(owner: owner, existing: [blocked]),
            doc(blocked.maxX + Placement.gapX, blocked.minY)
        )
    }
}
