import CoreGraphics
import XCTest
@testable import TarmacKit

/// The overlay-level offscreen-hint logic: priority, the single ⏎-fly target,
/// the pill label and the per-edge greedy stacking. The edge geometry it builds
/// on (`BoardWayfinding.hintPlacement`) is tested in `BoardWayfindingTests`.
final class OffscreenHintLayoutTests: XCTestCase {
    private typealias Layout = OffscreenHintLayout

    private func hint(_ cardID: String, _ center: CGPoint, _ signal: Layout.Signal, _ z: Int) -> Layout.Hint {
        Layout.Hint(cardID: cardID, centerView: center, signal: signal, label: cardID, z: z)
    }

    // MARK: - priority

    func testBellAlwaysOutranksLiveAndZBreaksTiesWithinAClass() {
        XCTAssertEqual(Layout.priority(signal: .bell, z: 5), 1005)
        XCTAssertEqual(Layout.priority(signal: .live, z: 5), 5)
        XCTAssertGreaterThan(Layout.priority(signal: .bell, z: 0), Layout.priority(signal: .live, z: 999))
    }

    // MARK: - flyTarget

    func testFlyTargetIsNilForNoHints() {
        XCTAssertNil(Layout.flyTarget([]))
    }

    func testABellWithLowerZBeatsAHigherZLive() {
        XCTAssertEqual(
            Layout.flyTarget([hint("live", .zero, .live, 100), hint("bell", .zero, .bell, 1)]),
            "bell"
        )
    }

    func testAmongTwoBellsTheHigherZWins() {
        XCTAssertEqual(Layout.flyTarget([hint("lo", .zero, .bell, 1), hint("hi", .zero, .bell, 9)]), "hi")
    }

    func testEqualPriorityReturnsTheFirstInArrayOrder() {
        XCTAssertEqual(Layout.flyTarget([hint("first", .zero, .live, 5), hint("second", .zero, .live, 5)]), "first")
    }

    // MARK: - pillLabel

    func testPillLabelJoinsNameAndTimeWithAMiddleDotForABellAndIsTheNameForLive() {
        XCTAssertEqual(Layout.pillLabel(signal: .bell, name: "notes.md", hhmm: "14:32"), "notes.md · 14:32")
        XCTAssertEqual(Layout.pillLabel(signal: .live, name: "agent", hhmm: "14:32"), "agent")
    }

    // MARK: - stackPills

    private let view = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 80, height: 24)

    private func options(obstacles: [CGRect] = []) -> Layout.Options {
        let size = size
        return Layout.Options(edgeInset: 18, edgeMargin: 10, stackGap: 8, pillSize: { _ in size }, obstacles: obstacles)
    }

    private func rect(of pill: Layout.PlacedPill) -> CGRect {
        CGRect(x: pill.left, y: pill.top, width: size.width, height: size.height)
    }

    private func stack(_ hints: [Layout.Hint], obstacles: [CGRect] = []) -> [Layout.PlacedPill] {
        Layout.stackPills(hints, in: view, options: options(obstacles: obstacles))
    }

    func testStackPillsOfNoHintsIsEmpty() {
        XCTAssertEqual(stack([]), [])
    }

    func testSkipsHintsWhoseCenterIsInsideTheView() {
        XCTAssertEqual(stack([hint("in", CGPoint(x: 500, y: 400), .live, 0)]), [])
    }

    func testPlacesARightEdgeHintFlushRightClampedVertically() throws {
        let pill = try XCTUnwrap(stack([hint("r", CGPoint(x: 2000, y: 400), .bell, 0)]).first)
        XCTAssertEqual(pill.edge, .right)
        XCTAssertEqual(pill.arrow, "→")
        XCTAssertEqual(pill.left, 1000 - 80 - 10, "maxX - width - margin")
        XCTAssertEqual(pill.top, 400 - 12, "clamp(centerY - height / 2, ...)")
    }

    func testPlacesLeftTopAndBottomHintsFlushToTheirEdge() throws {
        let left = try XCTUnwrap(stack([hint("l", CGPoint(x: -500, y: 300), .live, 0)]).first)
        XCTAssertEqual(left.edge, .left)
        XCTAssertEqual(left.arrow, "←")
        XCTAssertEqual(CGPoint(x: left.left, y: left.top), CGPoint(x: 10, y: 288))

        let top = try XCTUnwrap(stack([hint("t", CGPoint(x: 500, y: -300), .live, 0)]).first)
        XCTAssertEqual(top.edge, .top)
        XCTAssertEqual(top.arrow, "↑")
        XCTAssertEqual(CGPoint(x: top.left, y: top.top), CGPoint(x: 460, y: 10))

        let bottom = try XCTUnwrap(stack([hint("b", CGPoint(x: 500, y: 2000), .live, 0)]).first)
        XCTAssertEqual(bottom.edge, .bottom)
        XCTAssertEqual(bottom.arrow, "↓")
        XCTAssertEqual(CGPoint(x: bottom.left, y: bottom.top), CGPoint(x: 460, y: 766))
    }

    func testNudgesASecondOverlappingRightEdgePillDownByAtLeastTheStackGap() throws {
        let pills = stack([
            hint("a", CGPoint(x: 2000, y: 400), .bell, 0),
            hint("b", CGPoint(x: 2000, y: 405), .bell, 0),
        ])
        let a = try XCTUnwrap(pills.first { $0.cardID == "a" })
        let b = try XCTUnwrap(pills.first { $0.cardID == "b" })
        XCTAssertGreaterThanOrEqual(b.top, a.top + size.height + 8)
    }

    func testClampsAPillThatWouldExceedMaxY() throws {
        let pill = try XCTUnwrap(stack([hint("low", CGPoint(x: 2000, y: 5000), .bell, 0)]).first)
        XCTAssertEqual(pill.top, 800 - 24 - 10, "maxY - height - margin")
    }

    /// Naive placement (no obstacles) would land this pill at {920, 388, 80, 24};
    /// the obstacle overlaps that band.
    func testNudgesAPillClearOfAnUnrelatedObstacleItWouldOtherwiseLandOn() throws {
        let obstacle = CGRect(x: 900, y: 380, width: 100, height: 40)
        let pill = try XCTUnwrap(stack([hint("r", CGPoint(x: 2000, y: 400), .bell, 0)], obstacles: [obstacle]).first)
        XCTAssertFalse(Placement.rectsIntersect(rect(of: pill), obstacle))
        XCTAssertGreaterThan(pill.top, 388)
    }

    func testLandsInTheGapBetweenTwoObstaclesRatherThanOvershootingTheSecond() throws {
        let obstacleA = CGRect(x: 900, y: 180, width: 100, height: 40)
        let obstacleB = CGRect(x: 900, y: 260, width: 100, height: 40)
        let pill = try XCTUnwrap(
            stack([hint("b", CGPoint(x: 2000, y: 200), .bell, 0)], obstacles: [obstacleA, obstacleB]).first
        )
        XCTAssertEqual(pill.top, 228, "obstacleA.maxY + stackGap")
        let placed = CGRect(x: 910, y: pill.top, width: size.width, height: size.height)
        XCTAssertFalse(Placement.rectsIntersect(placed, obstacleA))
        XCTAssertFalse(Placement.rectsIntersect(placed, obstacleB))
    }

    /// Obstacles carry no card id, so there is no way to exempt "own card": an
    /// obstacle exactly where the hinted card's own rect would be still pushes the
    /// pill clear of it.
    func testNudgesAwayFromAnObstacleEvenWhenItCoincidesWithTheHintedCardsOwnSliver() throws {
        let ownCard = CGRect(x: 900, y: 380, width: 100, height: 40)
        let pill = try XCTUnwrap(stack([hint("r", CGPoint(x: 2000, y: 400), .bell, 0)], obstacles: [ownCard]).first)
        XCTAssertFalse(Placement.rectsIntersect(rect(of: pill), ownCard))
    }

    func testNeverSuppressesAPillEvenWhenTheObstacleBandIsFullySaturated() throws {
        let saturating = CGRect(x: 900, y: -1000, width: 100, height: 3000)
        let pills = stack([hint("r", CGPoint(x: 2000, y: 400), .bell, 0)], obstacles: [saturating])
        XCTAssertEqual(pills.count, 1)
        let pill = try XCTUnwrap(pills.first)
        XCTAssertGreaterThanOrEqual(pill.top, 10, "clamped within [posLo, posHi]")
        XCTAssertLessThanOrEqual(pill.top, 800 - 24 - 10)
    }

    /// A maximized on-screen card spans nearly the whole right band; four
    /// offscreen bells land close together on the same edge. Each pill must still
    /// avoid every other pill, though avoiding the obstacle too is best-effort.
    func testNeverStacksSameEdgePillsOnTopOfEachOtherWhenAnObstacleSaturatesTheBand() {
        let obstacle = CGRect(x: 900, y: 300, width: 100, height: 460)
        let pills = stack(
            [
                hint("a", CGPoint(x: 2000, y: 400), .bell, 0),
                hint("b", CGPoint(x: 2000, y: 412), .bell, 0),
                hint("c", CGPoint(x: 2000, y: 424), .bell, 0),
                hint("d", CGPoint(x: 2000, y: 436), .bell, 0),
            ],
            obstacles: [obstacle]
        )
        XCTAssertEqual(pills.count, 4)
        let rects = pills.map(rect(of:))
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(Placement.rectsIntersect(rects[i], rects[j]), "pills \(i) and \(j) overlap")
            }
            // The overlay clips at the viewport edge: an out-of-bounds pill would
            // render nowhere at all, which is worse than the overlap being avoided.
            XCTAssertGreaterThanOrEqual(rects[i].minY, 10)
            XCTAssertLessThanOrEqual(rects[i].minY, 800 - 24 - 10)
        }
    }

    func testStaysWithinViewportBoundsWhenAnObstacleForcesALaterSiblingToJumpAGap() throws {
        let obstacle = CGRect(x: 900, y: 492, width: 100, height: 416)
        let pills = stack(
            [hint("a", CGPoint(x: 2000, y: 300), .bell, 0), hint("b", CGPoint(x: 2000, y: 550), .bell, 0)],
            obstacles: [obstacle]
        )
        for pill in pills {
            XCTAssertGreaterThanOrEqual(pill.top, 10)
            XCTAssertLessThanOrEqual(pill.top, 800 - 24 - 10)
        }
        XCTAssertEqual(pills.count, 2)
        let first = try XCTUnwrap(pills.first)
        let last = try XCTUnwrap(pills.last)
        XCTAssertFalse(Placement.rectsIntersect(rect(of: first), rect(of: last)))
    }

    func testComposesObstacleAvoidanceWithSiblingStackGapInOnePass() throws {
        let obstacle = CGRect(x: 900, y: 118, width: 100, height: 22)
        let pills = stack(
            [hint("a", CGPoint(x: 2000, y: 100), .bell, 0), hint("b", CGPoint(x: 2000, y: 105), .bell, 0)],
            obstacles: [obstacle]
        )
        let a = try XCTUnwrap(pills.first { $0.cardID == "a" })
        let b = try XCTUnwrap(pills.first { $0.cardID == "b" })
        XCTAssertGreaterThanOrEqual(b.top, a.top + size.height + 8)
        XCTAssertFalse(Placement.rectsIntersect(rect(of: b), obstacle))
    }

    func testEqualAlongPositionsKeepTheInputOrderOnTheEdge() throws {
        let pills = stack([
            hint("first", CGPoint(x: 2000, y: 400), .live, 0),
            hint("second", CGPoint(x: 2000, y: 400), .live, 0),
        ])
        let first = try XCTUnwrap(pills.first { $0.cardID == "first" })
        let second = try XCTUnwrap(pills.first { $0.cardID == "second" })
        XCTAssertLessThan(first.top, second.top)
    }

    // MARK: - occluded

    /// An occluded pill is painted under the cards, the rest keep the over-card
    /// overlay (#126), so the flag must agree with the pill's own placed rect, not
    /// with which branch produced it.
    func testOccludedIsFalseWhenThereAreNoObstaclesAtAll() throws {
        let pill = try XCTUnwrap(stack([hint("r", CGPoint(x: 2000, y: 400), .bell, 0)]).first)
        XCTAssertFalse(pill.occluded)
    }

    func testOccludedIsFalseForAPillNudgedIntoAFreeGap() throws {
        let obstacleA = CGRect(x: 900, y: 180, width: 100, height: 40)
        let obstacleB = CGRect(x: 900, y: 260, width: 100, height: 40)
        let pill = try XCTUnwrap(
            stack([hint("r", CGPoint(x: 2000, y: 200), .bell, 0)], obstacles: [obstacleA, obstacleB]).first
        )
        XCTAssertFalse(pill.occluded)
    }

    func testOccludedIsTrueWhenTheBandIsSaturatedAndThePillLandsOnACard() throws {
        let saturating = CGRect(x: 900, y: -1000, width: 100, height: 3000)
        let pill = try XCTUnwrap(
            stack([hint("r", CGPoint(x: 2000, y: 400), .bell, 0)], obstacles: [saturating]).first
        )
        XCTAssertTrue(Placement.rectsIntersect(rect(of: pill), saturating))
        XCTAssertTrue(pill.occluded)
    }

    /// Some of these clear the card and some cannot; the flag has to track each
    /// pill individually, so a blanket true or false would fail here.
    func testOccludedAgreesWithThePlacedRectForEveryPillOfASaturatedMultiPillEdge() {
        let obstacle = CGRect(x: 900, y: 300, width: 100, height: 460)
        let pills = stack(
            [
                hint("a", CGPoint(x: 2000, y: 400), .bell, 0),
                hint("b", CGPoint(x: 2000, y: 412), .bell, 0),
                hint("c", CGPoint(x: 2000, y: 424), .bell, 0),
                hint("d", CGPoint(x: 2000, y: 436), .bell, 0),
            ],
            obstacles: [obstacle]
        )
        XCTAssertEqual(pills.count, 4)
        for pill in pills {
            XCTAssertEqual(pill.occluded, Placement.rectsIntersect(rect(of: pill), obstacle), pill.cardID)
        }
        XCTAssertTrue(pills.contains { $0.occluded })
        XCTAssertTrue(pills.contains { !$0.occluded })
    }

    /// The raw gap between A and B is 36 pt — wider than the 24 pt pill, narrower
    /// than the 24 + 2·8 the padded intervals demand — so the gap search finds no
    /// qualifying gap and falls back to the clamped desired position, which
    /// happens to sit 6 pt clear of both cards. A flag derived from "the search
    /// fell back", or from the stackGap-padded intervals, would call this
    /// occluded and demote a pill that covers nothing.
    func testOccludedIsFalseWhenTheGapSearchFallsBackButThePillStillLandsClear() throws {
        let a = CGRect(x: 900, y: 0, width: 100, height: 400)
        let b = CGRect(x: 900, y: 436, width: 100, height: 364)
        let pill = try XCTUnwrap(stack([hint("r", CGPoint(x: 2000, y: 418), .bell, 0)], obstacles: [a, b]).first)
        XCTAssertEqual(pill.left, 910)
        XCTAssertEqual(pill.top, 406, "the fallback position, not a gap-search result")
        XCTAssertFalse(Placement.rectsIntersect(rect(of: pill), a))
        XCTAssertFalse(Placement.rectsIntersect(rect(of: pill), b))
        XCTAssertFalse(pill.occluded)
    }

    func testOccludedIsTrueWhenThePillOverlapsAnyObstacleNotOnlyAllOfThem() throws {
        let near = CGRect(x: 900, y: -1000, width: 100, height: 3000)
        let far = CGRect(x: 0, y: 0, width: 60, height: 60)
        let pill = try XCTUnwrap(stack([hint("r", CGPoint(x: 2000, y: 400), .bell, 0)], obstacles: [near, far]).first)
        XCTAssertTrue(Placement.rectsIntersect(rect(of: pill), near))
        XCTAssertFalse(Placement.rectsIntersect(rect(of: pill), far))
        XCTAssertTrue(pill.occluded)
    }
}
