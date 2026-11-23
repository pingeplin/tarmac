import CoreGraphics
import XCTest

@testable import TarmacKit

/// The overlay-level offscreen-hint logic: the single ⏎-fly target,
/// the pill label and the per-edge greedy stacking. The edge geometry it builds
/// on (`BoardWayfinding.hintPlacement`) is tested in `BoardWayfindingTests`.
final class OffscreenHintsTests: XCTestCase {
    private typealias Layout = OffscreenHintLayout

    private func hint(_ cardID: String, _ center: CGPoint, _ signal: CardSignal, _ z: Int) -> Layout.Hint {
        Layout.Hint(cardID: cardID, centerView: center, signal: signal, label: .literal(cardID), z: z, signalAt: nil)
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

    func testS24TheRankWinsWhateverTheZ() {
        XCTAssertEqual(Layout.flyTarget([hint("live", .zero, .live, 5000), hint("bell", .zero, .bell, 0)]), "bell")
        XCTAssertEqual(Layout.flyTarget([hint("done", .zero, .done, 9), hint("exit", .zero, .exit, 1)]), "exit")
        XCTAssertEqual(
            Layout.flyTarget([hint("blocked", .zero, .blocked, 1), hint("bell", .zero, .bell, 9)]), "blocked")
        XCTAssertEqual(Layout.flyTarget([hint("first", .zero, .bell, 3), hint("second", .zero, .bell, 3)]), "first")
    }

    func testAnEqualRankAndZReturnsTheFirstInArrayOrder() {
        XCTAssertEqual(Layout.flyTarget([hint("first", .zero, .live, 5), hint("second", .zero, .live, 5)]), "first")
    }

    // MARK: - shown (#373)

    private func signalled(_ cardID: String, _ signal: CardSignal, at: UInt64?, z: Int = 0) -> Layout.Hint {
        Layout.Hint(cardID: cardID, centerView: .zero, signal: signal, label: .literal(cardID), z: z, signalAt: at)
    }

    private func lives(_ count: Int, suffix: String = "", zBase: Int = 0) -> [Layout.Hint] {
        (0..<count).map { signalled("live\($0)\(suffix)", .live, at: nil, z: zBase + $0) }
    }

    func testTheCapIsTen() {
        XCTAssertEqual(Layout.maxPills, 10)
    }

    func testTenOrFewerHintsAreAllShownUnchanged() {
        let hints = [signalled("old", .bell, at: 1, z: 1)] + lives(8) + [signalled("new", .bell, at: 9, z: 0)]
        XCTAssertEqual(Layout.shown(hints), hints)
    }

    func testABlockedHintIsKeptOverHigherZLowerRanks() {
        let hints = lives(10, zBase: 100) + [signalled("blocked", .blocked, at: 1, z: 0)]
        let shown = Layout.shown(hints).map(\.cardID)
        XCTAssertTrue(shown.contains("blocked"))
        XCTAssertFalse(shown.contains("live0"))
    }

    func testRankComesBeforeTime() {
        let hints =
            (0..<10).map { signalled("done\($0)", .done, at: 1000 + UInt64($0)) }
            + [signalled("exit", .exit, at: 1)]
        XCTAssertTrue(Layout.shown(hints).map(\.cardID).contains("exit"))
        XCTAssertFalse(Layout.shown(hints).map(\.cardID).contains("done0"))
    }

    func testWithinARankTheNewerSignalWinsWhateverTheZ() {
        let hints =
            [signalled("old", .bell, at: 5, z: 99)]
            + (0..<10).map { signalled("bell\($0)", .bell, at: 10 + UInt64($0), z: 0) }
        XCTAssertFalse(Layout.shown(hints).map(\.cardID).contains("old"))
    }

    func testLivePillsFallBackToZ() {
        let hints = lives(11)
        XCTAssertFalse(Layout.shown(hints).map(\.cardID).contains("live0"))
    }

    func testEqualTimesFallToTheHigherZThenTheEarlierHint() {
        let byZ = [signalled("low", .exit, at: 7, z: 1)] + (0..<10).map { signalled("e\($0)", .exit, at: 7, z: 2) }
        XCTAssertFalse(Layout.shown(byZ).map(\.cardID).contains("low"))
        let byOrder = (0..<11).map { signalled("e\($0)", .exit, at: 7, z: 2) }
        XCTAssertEqual(Layout.shown(byOrder).map(\.cardID), (0..<10).map { "e\($0)" })
    }

    func testTheShownHintsKeepTheirInputOrder() {
        let hints = lives(5) + [signalled("blocked", .blocked, at: 1)] + lives(6, suffix: "b")
        XCTAssertEqual(
            Layout.shown(hints).map(\.cardID),
            ["live1", "live2", "live3", "live4", "blocked", "live1b", "live2b", "live3b", "live4b", "live5b"]
        )
    }

    func testSelectShowsTheCappedPillsAndFliesToTheBestOfEveryHint() {
        let hints =
            [signalled("old", .bell, at: 1, z: 99)]
            + (0..<10).map { signalled("bell\($0)", .bell, at: 10 + UInt64($0), z: 0) }
        let selection = Layout.select(hints, in: CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertEqual(selection.shown, Layout.shown(hints))
        XCTAssertEqual(selection.flyTarget, "old")
    }

    // MARK: - select drops the cards on screen

    private let screen = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testSelectDropsAHintWhoseCentreIsOnScreen() {
        let selection = Layout.select(
            [hint("on", CGPoint(x: 400, y: 300), .bell, 0), hint("off", CGPoint(x: 900, y: 300), .bell, 0)], in: screen
        )
        XCTAssertEqual(selection.shown.map(\.cardID), ["off"])
    }

    func testACentreOnTheLeadingEdgeIsOnScreenAndOnTheTrailingEdgeIsNot() {
        let edges = [
            hint("minX", CGPoint(x: 0, y: 300), .live, 0), hint("maxX", CGPoint(x: 800, y: 300), .live, 0),
            hint("minY", CGPoint(x: 400, y: 0), .live, 0), hint("maxY", CGPoint(x: 400, y: 600), .live, 0),
        ]
        XCTAssertEqual(Layout.select(edges, in: screen).shown.map(\.cardID), ["maxX", "maxY"])
    }

    func testAnOnScreenCardIsNeverTheFlyTarget() {
        let selection = Layout.select(
            [hint("on", CGPoint(x: 400, y: 300), .blocked, 9), hint("off", CGPoint(x: -50, y: 300), .live, 0)],
            in: screen
        )
        XCTAssertEqual(selection.flyTarget, "off")
        XCTAssertNil(Layout.select([hint("on", CGPoint(x: 400, y: 300), .blocked, 9)], in: screen).flyTarget)
    }

    func testAnOnScreenCardTakesNoPillFromTheCap() {
        let off = (0..<Layout.maxPills).map { hint("off\($0)", CGPoint(x: 900, y: 300), .live, $0) }
        let on = hint("on", CGPoint(x: 400, y: 300), .blocked, 0)
        XCTAssertEqual(Layout.select([on] + off, in: screen).shown, off)
    }

    func testTheSignalTimeIsTheTimeOfTheShownSignal() {
        let at = { (signal: CardSignal) in
            Layout.signalAt(signal, reportAtMs: 1, bellAtMs: 2, exitAtMs: 3)
        }
        XCTAssertEqual(at(.blocked), 1)
        XCTAssertEqual(at(.done), 1)
        XCTAssertEqual(at(.bell), 2)
        XCTAssertEqual(at(.exit), 3)
        XCTAssertNil(at(.live))
    }

    // MARK: - pillLabel

    /// The label of a pill at 14:32; `quote` is a report's text.
    private func pill(_ quote: String?, _ signal: CardSignal = .blocked, name: String = "claude") -> InlineText {
        Layout.pillLabel(signal: signal, name: name, hhmm: "14:32", quote: quote.map(InlineMarkdown.line))
    }

    func testPillLabelJoinsNameAndTimeWithAMiddleDotForABellAndIsTheNameForLive() {
        XCTAssertEqual(pill(nil, .bell, name: "notes.md").plain, "notes.md · 14:32")
        XCTAssertEqual(pill("ignored", .live, name: "agent").plain, "agent")
    }

    func testS25AReportPillQuotesTheStartOfItsTextOnOneLine() {
        XCTAssertEqual(pill("abcdefghij\n  klmnopqrstuvwxyz0123").plain, "claude · “abcdefghij klmnopqrstuv…”")
        let exactly24 = "abcdefghijklmnopqrstuvwx"
        XCTAssertEqual(pill(exactly24, .done).plain, "claude · “\(exactly24)”")
    }

    /// Cut by Unicode scalars, not by characters: 13 decomposed `é` are 26
    /// scalars, so the pill keeps 23 of them.
    func testS25TheQuoteIsCutByUnicodeScalars() {
        let text = String(repeating: "e\u{301}", count: 13)
        let kept = String(repeating: "e\u{301}", count: 11) + "e"
        XCTAssertEqual(
            pill(text).plain.unicodeScalars.map(\.value), "claude · “\(kept)…”".unicodeScalars.map(\.value)
        )
    }

    func testS25ADoneWithNoTextAnExitABellAndLiveReadTheirWords() {
        XCTAssertEqual(pill(nil, .done).plain, "claude · report")
        XCTAssertEqual(pill(nil, .exit).plain, "claude · exited")
        XCTAssertEqual(pill("x", .bell).plain, "claude · 14:32")
        XCTAssertEqual(pill(nil, .live).plain, "claude")
    }

    // MARK: - pillLabel, inline markdown (spec 2611.0017)

    func testS7ThePillCountsRenderedScalars() {
        XCTAssertEqual(
            pill("Need OK to run [cargo test](u) now please").runs,
            [p("claude · “Need OK to run "), l("cargo te"), p("…”")]
        )
    }

    func testS10APillQuoteWithNoMarkdownReadsAsBefore() {
        for text in S10.texts {
            XCTAssertEqual(pill(text, .done), .literal("claude · “\(ChromeText.oneLine(text))”"), text)
        }
    }

    func testS8ThePillsNameIsLiteral() {
        XCTAssertEqual(pill("ok", name: "*scratch*"), .literal("*scratch* · “ok”"))
    }

    func testS19APillCutInACodeRunClosesTheRunBeforeTheEllipsis() {
        XCTAssertEqual(
            pill("`abcdefghijklmnopqrstuvwxyz`").runs, [p("claude · “"), c("abcdefghijklmnopqrstuvw"), p("…”")]
        )
    }

    func testS21ExactlyTwentyFourRenderedScalarsAreNotCut() {
        XCTAssertEqual(
            pill("**abcdefghijklmnopqrstuvwx**").runs, [p("claude · “"), b("abcdefghijklmnopqrstuvwx"), p("”")])
    }

    func testS23OtherPillKindsAreOnePlainRunOfTodaysString() {
        XCTAssertEqual(pill(nil, .bell, name: "notes.md"), .literal("notes.md · 14:32"))
        XCTAssertEqual(pill("**x**", .live, name: "agent"), .literal("agent"))
        XCTAssertEqual(pill(nil, .exit), .literal("claude · exited"))
        XCTAssertEqual(pill(nil, .done), .literal("claude · report"))
        XCTAssertEqual(pill("**x**", .bell), .literal("claude · 14:32"))
    }

    // MARK: - stackPills

    private let view = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 80, height: 24)

    private func options(obstacles: [CGRect] = [], chrome: [CGRect] = []) -> Layout.Options {
        let size = size
        return Layout.Options(
            edgeInset: 18, edgeMargin: 10, stackGap: 8, pillSize: { _ in size }, obstacles: obstacles, chrome: chrome
        )
    }

    private func rect(of pill: Layout.PlacedPill) -> CGRect {
        CGRect(x: pill.left, y: pill.top, width: size.width, height: size.height)
    }

    private func stack(
        _ hints: [Layout.Hint], obstacles: [CGRect] = [], chrome: [CGRect] = []
    ) -> [Layout.PlacedPill] {
        Layout.stackPills(hints, in: view, options: options(obstacles: obstacles, chrome: chrome))
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

    /// The flag says a pill covers card content, so it must agree with the pill's
    /// own placed rect, not with which branch produced it.
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

    // MARK: - the pieces the first fixtures never reached

    private func pill(
        size: CGSize,
        view: CGRect,
        center: CGPoint,
        obstacles: [CGRect] = []
    ) throws -> Layout.PlacedPill {
        let options = Layout.Options(
            edgeInset: 18, edgeMargin: 10, stackGap: 8, pillSize: { _ in size }, obstacles: obstacles
        )
        let hint = Layout.Hint(
            cardID: "h", centerView: center, signal: .live, label: .literal("h"), z: 0, signalAt: nil)
        return try XCTUnwrap(Layout.stackPills([hint], in: view, options: options).first)
    }

    /// 400 − 23 / 2 = 388.5, which rounds up to 389; unrounded it would stay 388.5.
    func testAFractionalPositionRoundsHalfUp() throws {
        let placed = try pill(size: CGSize(width: 80, height: 23), view: view, center: CGPoint(x: 2000, y: 400))
        XCTAssertEqual(placed.top, 389)
    }

    /// Both positions land on a negative half: −411.5 rounds up to −411 and −55.5 to
    /// −55, where `rounded()` would give −412 and −56.
    func testANegativeHalfRoundsTowardPositiveInfinity() throws {
        let negativeView = CGRect(x: -1000, y: -800, width: 1000, height: 800)
        let placed = try pill(
            size: CGSize(width: 45.5, height: 23), view: negativeView, center: CGPoint(x: 500, y: -400)
        )
        XCTAssertEqual(placed.left, -55)
        XCTAssertEqual(placed.top, -411)
    }

    func testAnObstacleOutsideThePillsBandDoesNotMoveIt() throws {
        let farSide = CGRect(x: 0, y: 380, width: 100, height: 40)
        let placed = try pill(size: size, view: view, center: CGPoint(x: 2000, y: 400), obstacles: [farSide])
        XCTAssertEqual(placed.top, 388)
        XCTAssertFalse(placed.occluded)
    }

    func testPillsOnAllFourEdgesComeOutLeftRightTopBottom() {
        let pills = stack([
            hint("b", CGPoint(x: 500, y: 2000), .live, 0),
            hint("t", CGPoint(x: 500, y: -300), .live, 0),
            hint("r", CGPoint(x: 2000, y: 400), .live, 0),
            hint("l", CGPoint(x: -500, y: 300), .live, 0),
        ])
        XCTAssertEqual(pills.map(\.cardID), ["l", "r", "t", "b"])
    }

    /// Fourteen pills share one spot on a band that holds twelve. Each starts a
    /// `stackGap` past its sibling, so the last two overflow the viewport rather than
    /// stack on a sibling or vanish.
    func testAnOverSaturatedEdgeOverflowsForwardInsteadOfOverlappingOrVanishing() {
        let hints = (0..<14).map { hint("h\($0)", CGPoint(x: 2000, y: 400), .live, 0) }
        let tops = stack(hints).map(\.top)
        XCTAssertEqual(tops, (0..<14).map { 388 + 32 * CGFloat($0) })
        XCTAssertGreaterThan(tops[12], 800 - 24 - 10, "the overflow is past the viewport margin")
    }

    /// The overflow also steps past an obstacle in its way: 772 would sit on it, so
    /// the pill moves to the obstacle's padded far edge.
    func testAnOverflowingPillStepsPastAnObstacleInItsWay() {
        let obstacle = CGRect(x: 900, y: 780, width: 100, height: 120)
        let hints = (0..<14).map { hint("h\($0)", CGPoint(x: 2000, y: 400), .live, 0) }
        let tops = stack(hints, obstacles: [obstacle]).map(\.top)
        XCTAssertEqual(Array(tops[0..<12]), (0..<12).map { 388 + 32 * CGFloat($0) })
        XCTAssertEqual(tops[12], 908, "obstacle.maxY + stackGap")
        XCTAssertEqual(tops[13], 940, "one stackGap past the sibling")
    }

    // MARK: - the corner chrome

    /// The minimap over this view: 132×88, 12 in from the right and the bottom.
    private let minimap = CGRect(x: 856, y: 700, width: 132, height: 88)
    /// A toast a gap above it, in the same right-hand column.
    private let toast = CGRect(x: 680, y: 650, width: 296, height: 42)

    private func assertClear(
        _ pills: [Layout.PlacedPill], of chrome: [CGRect], file: StaticString = #filePath, line: UInt = #line
    ) {
        let rects = pills.map(rect(of:))
        for (pill, placed) in zip(pills, rects) {
            for rect in chrome {
                XCTAssertFalse(
                    Placement.rectsIntersect(placed, rect), "\(pill.cardID) is under \(rect)", file: file, line: line
                )
            }
            XCTAssertTrue(
                view.insetBy(dx: 10, dy: 10).contains(placed), "\(pill.cardID) left the view", file: file, line: line)
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(
                    Placement.rectsIntersect(rects[i], rects[j]), "pills \(i) and \(j) overlap", file: file, line: line
                )
            }
        }
    }

    /// Naive placement would put this pill at {880, 766}, under the minimap.
    func testABottomPillUnderTheMinimapShiftsLeftOfIt() throws {
        let pill = try XCTUnwrap(stack([hint("b", CGPoint(x: 920, y: 2000), .live, 0)], chrome: [minimap]).first)
        XCTAssertEqual(pill.edge, .bottom)
        XCTAssertEqual(pill.left, 856 - 8 - 80, "minimap.minX - stackGap - width")
        XCTAssertEqual(pill.top, 766)
        XCTAssertFalse(pill.occluded)
    }

    /// The card's padded span is [392, 508] and the pill wants 440: the gap to
    /// its right (508) is nearer than the one to its left (312), and the left wins.
    func testABottomPillThatMustMovePrefersTheLeft() throws {
        let card = CGRect(x: 400, y: 700, width: 100, height: 200)
        let pill = try XCTUnwrap(stack([hint("b", CGPoint(x: 480, y: 2000), .live, 0)], obstacles: [card]).first)
        XCTAssertEqual(pill.left, 392 - 80)
        XCTAssertFalse(pill.occluded)
    }

    /// No room to the left of the card: the nearest gap, to its right, as before.
    func testABottomPillWithNoRoomToTheLeftTakesTheNearestGap() throws {
        let card = CGRect(x: 0, y: 700, width: 300, height: 200)
        let pill = try XCTUnwrap(stack([hint("b", CGPoint(x: 240, y: 2000), .live, 0)], obstacles: [card]).first)
        XCTAssertEqual(pill.left, 308, "card.maxX + stackGap")
    }

    func testTwoBottomPillsAtTheMinimapCornerBothClearIt() {
        let pills = stack(
            [hint("a", CGPoint(x: 900, y: 2000), .live, 0), hint("b", CGPoint(x: 960, y: 2000), .live, 0)],
            chrome: [minimap]
        )
        XCTAssertEqual(pills.count, 2)
        assertClear(pills, of: [minimap])
        XCTAssertEqual(
            pills.sorted { $0.left < $1.left }.map(\.cardID), ["a", "b"], "the order along the edge is kept")
    }

    func testTwoBottomPillsAtTheLeftCornerStayInTheView() {
        let pills = stack(
            [hint("a", CGPoint(x: 30, y: 2000), .live, 0), hint("b", CGPoint(x: 31, y: 2000), .live, 0)],
            chrome: [minimap]
        )
        XCTAssertEqual(pills.count, 2)
        assertClear(pills, of: [minimap])
    }

    /// Clearing the minimap corner must not push the pills of the other corner
    /// out of the view.
    func testClearingTheMinimapKeepsTheLeftCornerPillsInTheView() {
        let pills = stack(
            [30, 31, 900, 960].map { hint("x\(Int($0))", CGPoint(x: $0, y: 2000), .live, 0) },
            chrome: [minimap]
        )
        XCTAssertEqual(pills.count, 4)
        assertClear(pills, of: [minimap])
    }

    func testClearingTheToastsKeepsTheTopCornerPillsInTheView() {
        let pills = stack(
            [30, 31, 740, 770].map { hint("y\(Int($0))", CGPoint(x: 2000, y: $0), .live, 0) },
            chrome: [toast, minimap]
        )
        XCTAssertEqual(pills.count, 4)
        assertClear(pills, of: [toast, minimap])
    }

    /// The zoom control over this view's bottom-left corner.
    private let zoomControl = CGRect(x: 12, y: 762, width: 160, height: 26)

    /// The card's padded span is [92, 708]: no room to its left past the zoom
    /// control, so the pill takes the gap to its right.
    func testABottomPillDoesNotShiftLeftUnderTheZoomControl() throws {
        let card = CGRect(x: 100, y: 600, width: 600, height: 300)
        let pill = try XCTUnwrap(
            stack([hint("b", CGPoint(x: 680, y: 2000), .live, 0)], obstacles: [card], chrome: [minimap, zoomControl])
                .first
        )
        XCTAssertEqual(pill.left, 708, "card.maxX + stackGap")
        assertClear([pill], of: [minimap, zoomControl])
    }

    /// Eleven pills fill the bottom band; one overflows whichever way the edge
    /// is resolved. Resolving it again from its end must not push out a second.
    func testResolvingAnEdgeFromItsEndPushesNoMorePillsOutOfTheView() {
        let pills = stack(
            (0..<11).map { hint("p\($0)", CGPoint(x: 100 + 80 * CGFloat($0), y: 2000), .live, 0) },
            chrome: [minimap]
        )
        XCTAssertEqual(pills.count, 11)
        let outside = pills.filter { !view.insetBy(dx: 10, dy: 10).contains(rect(of: $0)) }
        XCTAssertLessThanOrEqual(outside.count, 1, "\(outside.map(\.left))")
    }

    /// Forward leaves one pill under the minimap and two under the cards.
    /// Resolved from the end, every pill clears them, but the first two are
    /// pushed off the view's left side, so the forward placing stays.
    func testResolvingFromTheEndNeverPushesAPillOffTheView() {
        let cards = [
            CGRect(x: 606, y: 712, width: 294, height: 113), CGRect(x: 188, y: 507, width: 401, height: 297),
        ]
        let pills = stack(
            [73, 154, 975, 145].map { hint("x\(Int($0))", CGPoint(x: $0, y: 2000), .live, 0) },
            obstacles: cards, chrome: [minimap]
        )
        XCTAssertEqual(pills.count, 4)
        let offView = pills.filter { !rect(of: $0).intersects(view) }
        XCTAssertEqual(offView.map(\.cardID), [])
    }

    /// Forward, the first pill takes the gap [690, 848] and the second is left
    /// under the minimap. Resolved from the end, the second takes the gap and
    /// the first goes under the card: one pill covered either way, so the
    /// forward placing stays.
    func testResolvingFromTheEndDoesNotTradeAPillUnderTheChromeForOneUnderACard() {
        let card = CGRect(x: -50, y: 700, width: 732, height: 200)
        let pills = stack(
            [hint("a", CGPoint(x: 100, y: 2000), .live, 0), hint("c", CGPoint(x: 960, y: 2000), .live, 0)],
            obstacles: [card], chrome: [minimap]
        )
        XCTAssertEqual(pills.map(\.left), [690, 910])
        XCTAssertFalse(pills.contains { $0.occluded })
    }

    /// The right band runs past the toast and the minimap; the pill wants 748.
    func testARightEdgePillNearTheBottomClearsTheToastAndTheMinimap() throws {
        let pill = try XCTUnwrap(
            stack([hint("r", CGPoint(x: 2000, y: 760), .live, 0)], chrome: [toast, minimap]).first
        )
        XCTAssertEqual(pill.edge, .right)
        XCTAssertEqual(pill.top, 650 - 8 - 24, "toast.minY - stackGap - height")
        assertClear([pill], of: [toast, minimap])
    }

    func testTwoRightEdgePillsAtTheBottomCornerBothClearTheToastAndTheMinimap() {
        let pills = stack(
            [hint("a", CGPoint(x: 2000, y: 740), .live, 0), hint("b", CGPoint(x: 2000, y: 770), .live, 0)],
            chrome: [toast, minimap]
        )
        XCTAssertEqual(pills.count, 2)
        assertClear(pills, of: [toast, minimap])
        XCTAssertEqual(pills.sorted { $0.top < $1.top }.map(\.cardID), ["a", "b"], "the order along the edge is kept")
    }

    /// The corner chrome is drawn over every pill, so a pill left under it
    /// covers no card: it is not occluded.
    func testAPillThatCannotClearTheChromeIsNotOccluded() throws {
        let saturating = CGRect(x: 900, y: -1000, width: 100, height: 3000)
        let pill = try XCTUnwrap(
            stack([hint("r", CGPoint(x: 2000, y: 400), .live, 0)], chrome: [saturating]).first
        )
        XCTAssertTrue(Placement.rectsIntersect(rect(of: pill), saturating))
        XCTAssertFalse(pill.occluded)
    }

    // MARK: - the last gap of a band (#375)

    private func offView(_ pills: [Layout.PlacedPill]) -> Int {
        pills.filter { !Placement.rectsIntersect(rect(of: $0), view) }.count
    }

    /// The card's padded span is [42, 840] and the band ends at 990: the pill
    /// fits the last gap, [840, 990].
    func testAPillFitsTheLastGapOfItsBand() throws {
        let card = CGRect(x: 50, y: 700, width: 782, height: 200)
        let pill = try XCTUnwrap(stack([hint("b", CGPoint(x: 800, y: 2000), .live, 0)], obstacles: [card]).first)
        XCTAssertEqual(pill.left, 840, "card.maxX + stackGap")
        XCTAssertFalse(pill.occluded)
    }

    /// With the last gap open, the first pill takes it and pushes its
    /// siblings off the view; the placing that leaves two pills under the
    /// card and none off the view stays.
    func testTheLastGapNeverPushesASiblingOffTheView() {
        let card = CGRect(x: -50, y: -20, width: 892, height: 300)
        let pills = stack(
            [100, 300, 930].map { hint("t\(Int($0))", CGPoint(x: $0, y: -2000), .live, 0) }, obstacles: [card])
        XCTAssertEqual(pills.count, 3)
        XCTAssertEqual(offView(pills), 0)
        XCTAssertEqual(pills.filter(\.occluded).count, 2)
    }

    func testTheLastGapPushesNoMorePillsOffTheViewThanBefore() {
        let card = CGRect(x: 898, y: -48, width: 700, height: 440)
        let pills = stack(
            [880, 894, 919].map { hint("t\(Int($0))", CGPoint(x: $0, y: -2000), .live, 0) }, obstacles: [card])
        XCTAssertEqual(pills.count, 3)
        XCTAssertEqual(offView(pills), 1)
        XCTAssertEqual(pills.filter(\.occluded).count, 1)
    }

    /// The bottom band overflows either way. With the last gap open, the
    /// first pill clears the card and every later one shifts right, so one
    /// more leaves the view: the placing that leaves it under the card stays.
    func testTheLastGapNeverTradesACoveredPillForOneOffTheView() {
        let view = CGRect(x: 0, y: 0, width: 701, height: 636)
        let sizes: [String: CGSize] = [
            "p0": CGSize(width: 186, height: 27), "p1": CGSize(width: 67, height: 21),
            "p2": CGSize(width: 168, height: 23), "p3": CGSize(width: 220, height: 25),
            "p4": CGSize(width: 210, height: 26), "p5": CGSize(width: 82, height: 23),
            "p6": CGSize(width: 52, height: 24),
        ]
        let centres: [String: CGFloat] = ["p0": 1, "p1": -141, "p2": 229, "p3": 784, "p4": 75, "p5": 429, "p6": 353]
        let hints = centres.keys.sorted().map { hint($0, CGPoint(x: centres[$0]!, y: 2000), .live, 0) }
        let cards = [
            CGRect(x: -332, y: 644, width: 924, height: 611), CGRect(x: -332, y: 529, width: 731, height: 313),
        ]
        let options = Layout.Options(
            edgeInset: 18, edgeMargin: 10, stackGap: 8, pillSize: { sizes[$0.cardID]! }, obstacles: cards
        )
        let pills = Layout.stackPills(hints, in: view, options: options)
        let rects = pills.map { CGRect(origin: CGPoint(x: $0.left, y: $0.top), size: sizes[$0.cardID]!) }
        XCTAssertEqual(pills.count, 7)
        XCTAssertEqual(rects.filter { !Placement.rectsIntersect($0, view) }.count, 3)
        XCTAssertEqual(pills.filter(\.occluded).count, 1)
    }

    /// The card's padded span is [824, 1460]: clipped at the band's end, it
    /// still covers the pill's wanted start, 910, so the pill moves left of it.
    func testTheCardPastTheLastPillStartStillBlocksTheBandsEnd() throws {
        let card = CGRect(x: 832, y: -189, width: 620, height: 250)
        let pill = try XCTUnwrap(stack([hint("t", CGPoint(x: 1000, y: -2000), .live, 0)], obstacles: [card]).first)
        XCTAssertEqual(pill.left, 832 - 8 - 80, "card.minX - stackGap - width")
        XCTAssertFalse(pill.occluded)
    }

    /// The card's padded span is [55, 651] and the minimap's [692, 796]. Only
    /// the full last gap, resolved from the end, puts the lower pill above
    /// the minimap and the upper one above the card.
    func testTheFullLastGapResolvedFromTheEndClearsTheCardAndTheMinimap() {
        let card = CGRect(x: 669, y: 63, width: 810, height: 580)
        let pills = stack(
            [hint("a", CGPoint(x: 3000, y: 683), .live, 0), hint("b", CGPoint(x: 3000, y: 588), .live, 0)],
            obstacles: [card], chrome: [zoomControl, minimap]
        )
        XCTAssertEqual(
            pills.map(\.top).sorted(), [63 - 8 - 24, 700 - 8 - 24],
            "card.minY and minimap.minY, less stackGap and height")
        assertClear(pills, of: [zoomControl, minimap])
        XCTAssertFalse(pills.contains { $0.occluded })
    }

    /// Found by a randomized search. Resolved from the end, the bottom band
    /// leaves one pill fewer under the minimap but pushes the first pill fully
    /// off the view's left side, so the forward placing stays.
    func testResolvingFromTheEndNeverTradesACoveredPillForOneOffTheView() {
        let cards = [CGRect(x: -234, y: 492, width: 250, height: 340), CGRect(x: 355, y: 789, width: 280, height: 540)]
        let pills = stack(
            [361, 957, 175, 388, 513, 39].map { hint("x\(Int($0))", CGPoint(x: $0, y: 2800), .live, 0) },
            obstacles: cards, chrome: [zoomControl, minimap, toast]
        )
        XCTAssertEqual(pills.count, 6)
        XCTAssertEqual(offView(pills), 0)
        XCTAssertEqual(pills.filter { Placement.rectsIntersect(rect(of: $0), minimap) }.count, 2)
    }
}
