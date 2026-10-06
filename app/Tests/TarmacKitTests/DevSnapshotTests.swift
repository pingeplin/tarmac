import CoreGraphics
import XCTest
@testable import TarmacKit

/// The QA driver's snapshot (spec 2609.0015, #166; guard facts and `borrowed`
/// from 2609.0018): the app's live UI state as the JSON tree that is both sent
/// and evaluated by `--until`.
final class DevSnapshotTests: XCTestCase {
    private typealias Input = DevSnapshot.Input
    private typealias Card = DevSnapshot.Card
    private typealias Terminal = DevSnapshot.Terminal
    private typealias Guard = DevSnapshot.QuitGuard

    private let view = CGRect(x: 24, y: 40, width: 1000, height: 700)

    private func terminal(
        live: Bool = true, dead: Bool = false, proc: String? = "zsh", selection: String? = nil, tail: String = "hi"
    ) -> Terminal {
        Terminal(live: live, dead: dead, cols: 80, rows: 24, proc: proc, selection: selection, scrollbackTail: tail)
    }

    private func term(_ terminal: Terminal? = nil, screenRect: CGRect? = nil, scroll: DevSnapshot.Scroll? = nil) -> Card {
        Card(
            id: "t-1", content: .term(terminal ?? self.terminal()),
            frame: CGRect(x: 10, y: 20, width: 400, height: 300), screenRect: screenRect, scroll: scroll
        )
    }

    private func doc(_ id: String = "/Users/e/a.b.md", scroll: DevSnapshot.Scroll? = nil) -> Card {
        Card(id: id, content: .doc, frame: CGRect(x: 500, y: 20, width: 300, height: 200), screenRect: nil, scroll: scroll)
    }

    private func scroll(laidOut: Bool = true, alpha: CGFloat = 1, thumb: CGRect? = nil) throws -> DevSnapshot.Scroll {
        DevSnapshot.Scroll(
            metrics: try XCTUnwrap(ScrollMetrics(offset: 30, visible: 100, total: 400)),
            laidOut: laidOut, alpha: alpha, thumb: thumb
        )
    }

    private func input(
        cards: [Card]? = nil,
        visibility: DevSnapshot.Visibility = .visible,
        viewport: DevSnapshot.Viewport = DevSnapshot.Viewport(zoom: 1, center: CGPoint(x: 500, y: 350)),
        selectedCard: String? = nil,
        borrowedCard: String? = nil,
        keyboardFocus: DevSnapshot.KeyboardFocus = .none,
        quitGuard: Guard? = nil,
        contentOrigin: CGPoint? = nil,
        fonts: DevSnapshot.Fonts? = nil,
        theme: DevSnapshot.Theme? = nil
    ) -> Input {
        var input = Input(
            boardID: "board-0",
            visibility: visibility,
            viewport: viewport,
            viewRect: view,
            contentOrigin: contentOrigin,
            cards: cards ?? [term(), doc()],
            selectedCard: selectedCard,
            borrowedCard: borrowedCard,
            keyboardFocus: keyboardFocus,
            quitGuard: quitGuard,
            fonts: fonts ?? DevSnapshot.Fonts(
                saved: [:], terminalFace: "SystemMono-Regular", terminalSize: 16,
                interfaceFace: "SystemMono-Regular", documentCSS: "system-ui", documentSize: 14
            )
        )
        if let theme { input.theme = theme }
        return input
    }

    private func fields(_ value: JSONValue?, file: StaticString = #filePath, line: UInt = #line) -> [String: JSONValue] {
        guard case .object(let fields)? = value else {
            XCTFail("not an object: \(String(describing: value))", file: file, line: line)
            return [:]
        }
        return fields
    }

    private func cards(_ snapshot: JSONValue, file: StaticString = #filePath, line: UInt = #line) -> [[String: JSONValue]] {
        guard case .array(let cards)? = fields(snapshot)["cards"] else {
            XCTFail("no cards array", file: file, line: line)
            return []
        }
        return cards.map { fields($0) }
    }

    private func card(_ snapshot: JSONValue, _ id: String) -> [String: JSONValue] {
        cards(snapshot).first { $0["id"] == .string(id) } ?? [:]
    }

    // MARK: - S1 shape

    func testS1TheSnapshotCarriesExactlyTheDocumentedTopLevelKeys() {
        let snapshot = fields(DevSnapshot.build(input()))
        XCTAssertEqual(
            snapshot.keys.sorted(),
            [
                "active_element", "board_id", "cards", "content_origin", "focused_card", "fonts", "quit_guard", "theme",
                "v", "viewport", "visibility",
            ]
        )
        XCTAssertEqual(snapshot["v"], 1)
        XCTAssertEqual(snapshot["board_id"], "board-0")
        XCTAssertEqual(
            snapshot["viewport"],
            ["zoom": 1, "cx": 500, "cy": 350, "view_rect": ["x": 24, "y": 40, "w": 1000, "h": 700]]
        )
    }

    // MARK: - content_origin (2610.0002 S6)

    /// Cocoa's screen points have their origin at the primary screen's
    /// bottom-left; a display point is measured from its top-left. Nothing is
    /// clamped: a screen above and left of the primary one is negative in both.
    func testS6ACocoaScreenPointBecomesADisplayPoint() {
        XCTAssertEqual(
            DevSnapshot.displayPoint(cocoa: CGPoint(x: 730, y: 1218), primaryScreenHeight: 1440),
            CGPoint(x: 730, y: 222)
        )
        XCTAssertEqual(
            DevSnapshot.displayPoint(cocoa: CGPoint(x: -500, y: 1600), primaryScreenHeight: 1440),
            CGPoint(x: -500, y: -160)
        )
    }

    func testS6TheSnapshotSaysWhereItsContentCoordinatesStartOnTheDisplay() {
        let shown = fields(DevSnapshot.build(input(contentOrigin: CGPoint(x: 730, y: 222))))
        XCTAssertEqual(shown["content_origin"], ["x": 730, "y": 222])

        let windowless = fields(DevSnapshot.build(input()))
        XCTAssertEqual(windowless["content_origin"], .null)
    }

    /// The board's own viewport, away from the defaults: `smoke.mjs` waits on
    /// `viewport.zoom` after every `zoom`.
    func testS1TheViewportIsTheOneSupplied() {
        let viewport = DevSnapshot.Viewport(zoom: 1.7, center: CGPoint(x: 12, y: -34))
        XCTAssertEqual(
            fields(DevSnapshot.build(input(viewport: viewport)))["viewport"],
            ["zoom": 1.7, "cx": 12, "cy": -34, "view_rect": ["x": 24, "y": 40, "w": 1000, "h": 700]]
        )
    }

    func testS1ACardCarriesItsIdKindAndWorldFrame() {
        let snapshot = DevSnapshot.build(input())
        XCTAssertEqual(card(snapshot, "t-1")["kind"], "term")
        XCTAssertEqual(card(snapshot, "/Users/e/a.b.md")["kind"], "doc")
        XCTAssertEqual(card(snapshot, "/Users/e/a.b.md")["board_rect"], ["x": 500, "y": 20, "w": 300, "h": 200])
        XCTAssertEqual(
            card(snapshot, "t-1").keys.sorted(), ["board_rect", "focused", "id", "kind", "screen_rect", "scroll", "term"]
        )
        XCTAssertEqual(
            card(snapshot, "/Users/e/a.b.md").keys.sorted(),
            ["board_rect", "borrowed", "focused", "id", "kind", "screen_rect", "scroll"]
        )
    }

    // MARK: - scroll (2610.0003 S15)

    func test2610S15ACardSaysWhereItsContentIsScrolledTo() throws {
        let snapshot = DevSnapshot.build(input(cards: [term(scroll: try scroll()), doc(scroll: try scroll())]))
        let expected: JSONValue = ["offset": 30, "visible": 100, "total": 400, "shown": true, "thumb": .null]
        XCTAssertEqual(card(snapshot, "t-1")["scroll"], expected)
        XCTAssertEqual(card(snapshot, "/Users/e/a.b.md")["scroll"], expected)
    }

    /// Shown is both facts: a thumb laid out, and an alpha above nothing.
    func test2610S15ShownNeedsAThumbLaidOutAndAnAlphaAboveZero() throws {
        func shown(_ scroll: DevSnapshot.Scroll) -> JSONValue? {
            fields(card(DevSnapshot.build(input(cards: [term(scroll: scroll)])), "t-1")["scroll"])["shown"]
        }
        XCTAssertEqual(shown(try scroll(alpha: 0.25)), true)
        XCTAssertEqual(shown(try scroll(laidOut: false, alpha: 1)), false)
        XCTAssertEqual(shown(try scroll(laidOut: true, alpha: 0)), false)
    }

    /// Where the thumb is, for a tool that aims at it; a stale frame of a
    /// thumb that is not laid out is no thumb.
    func test2610_0004S14ACardSaysWhereItsThumbIs() throws {
        func thumb(_ scroll: DevSnapshot.Scroll) -> JSONValue? {
            fields(card(DevSnapshot.build(input(cards: [term(scroll: scroll)])), "t-1")["scroll"])["thumb"]
        }
        let rect = CGRect(x: 379, y: 33, width: 10, height: 24)
        XCTAssertEqual(thumb(try scroll(thumb: rect)), ["x": 379, "y": 33, "w": 10, "h": 24])
        XCTAssertEqual(thumb(try scroll(thumb: nil)), .null)
        XCTAssertEqual(thumb(try scroll(laidOut: false, thumb: rect)), .null)
        XCTAssertEqual(thumb(try scroll(alpha: 0, thumb: rect)), ["x": 379, "y": 33, "w": 10, "h": 24], "a faded thumb")
    }

    func test2610_0004S14ShownDoesNotLookAtTheThumbsRect() throws {
        let snapshot = DevSnapshot.build(input(cards: [term(scroll: try scroll(alpha: 1, thumb: nil))]))
        XCTAssertEqual(fields(card(snapshot, "t-1")["scroll"])["shown"], true)
    }

    func test2610S15ACardWithNoMetricsSaysNull() {
        let snapshot = DevSnapshot.build(input())
        XCTAssertEqual(card(snapshot, "t-1")["scroll"], .null)
        XCTAssertEqual(card(snapshot, "/Users/e/a.b.md")["scroll"], .null)
    }

    /// The paths a scenario waits on: a null `scroll` resolves no `shown`.
    func test2610S15UntilCanWaitOnACardsScroll() throws {
        let snapshot = DevSnapshot.build(input(cards: [term(scroll: try scroll()), doc()]))
        func holds(_ source: String) throws -> Bool { DevUntil.evaluate(try DevUntil.parse(source), against: snapshot) }
        XCTAssertTrue(try holds("cards[t-1].scroll.shown == true"))
        XCTAssertTrue(try holds("cards[t-1].scroll.offset == 30"))
        XCTAssertTrue(try holds("cards[/Users/e/a.b.md].scroll == null"))
        XCTAssertFalse(try holds("cards[/Users/e/a.b.md].scroll.shown == false"))
    }

    // MARK: - S2 a doc card has no `term` key at all

    /// A `term` key holding null would read as a resolvable path to `--until`.
    func testS2ADocCardHasNoTermKeyAndATerminalHasExactlySix() throws {
        let snapshot = DevSnapshot.build(input())
        XCTAssertEqual(
            fields(card(snapshot, "t-1")["term"]).keys.sorted(),
            ["alive", "cols", "proc", "rows", "scrollback_tail", "selection"]
        )
        XCTAssertNil(card(snapshot, "/Users/e/a.b.md")["term"])
        XCTAssertFalse(try DevUntil.evaluate(DevUntil.parse("cards[/Users/e/a.b.md].term == null"), against: snapshot))
        XCTAssertFalse(try DevUntil.evaluate(DevUntil.parse("cards[/Users/e/a.b.md].term != null"), against: snapshot))
    }

    func testATerminalsFactsAreReportedAsMeasured() {
        let facts = fields(card(DevSnapshot.build(input(cards: [term(terminal(tail: "$ ls\na b"))])), "t-1")["term"])
        XCTAssertEqual(facts, [
            "alive": true, "cols": 80, "rows": 24, "proc": "zsh", "selection": .null, "scrollback_tail": "$ ls\na b",
        ])
    }

    /// The view's rows as it hands them over: a blank row inside the tail is
    /// output too, and `scrollback_tail == <an earlier tail>` compares them all.
    func testTheTailIsReportedExactlyBlankRowsIncluded() {
        let tail = "\n\n$ ls\n\na b\n  \n"
        XCTAssertEqual(facts(terminal(tail: tail))["scrollback_tail"], .string(tail))
        XCTAssertEqual(facts(terminal(tail: ""))["scrollback_tail"], "")
    }

    // MARK: - S3 screen_rect is the measurement, or null

    func testS3AnUnmeasuredCardReportsNullAndKeepsItsBoardRect() {
        let card = card(DevSnapshot.build(input()), "t-1")
        XCTAssertEqual(card["screen_rect"], .null)
        XCTAssertEqual(card["board_rect"], ["x": 10, "y": 20, "w": 400, "h": 300])
    }

    /// The two deliberately disagree. Reporting the projection would make the
    /// suite's "painted where the transform says" check compare it with itself.
    func testS3TheMeasuredRectIsReportedNotTheProjectionOfTheBoardRect() {
        let measured = CGRect(x: 999, y: 888, width: 77, height: 66)
        let source = input(cards: [term(screenRect: measured)])
        let card = card(DevSnapshot.build(source), "t-1")
        XCTAssertEqual(card["screen_rect"], ["x": 999, "y": 888, "w": 77, "h": 66])
        XCTAssertEqual(card["board_rect"], ["x": 10, "y": 20, "w": 400, "h": 300])
        XCTAssertNotEqual(DevSnapshot.screenRect(of: source.cards[0].frame, viewport: source.viewport, viewRect: view), measured)
    }

    /// A view that measured zero is an observation and must survive as one.
    func testS3AZeroSizeMeasurementIsMeasuredNotAbsent() {
        let zero = CGRect(x: 12, y: 34, width: 0, height: 0)
        let card = card(DevSnapshot.build(input(cards: [term(screenRect: zero)])), "t-1")
        XCTAssertEqual(card["screen_rect"], ["x": 12, "y": 34, "w": 0, "h": 0])
    }

    // MARK: - S5 absent facts are null, never empty strings

    private func facts(_ terminal: Terminal) -> [String: JSONValue] {
        fields(card(DevSnapshot.build(input(cards: [term(terminal)])), "t-1")["term"])
    }

    func testS5NoProcIsNull() {
        XCTAssertEqual(facts(terminal(proc: nil))["proc"], .null)
    }

    /// `""` would make `contains ""` match vacuously, so the normalisation is a
    /// decision and lives in the builder, not in the view that reads it.
    func testS5AnEmptySelectionIsNull() {
        XCTAssertEqual(facts(terminal(selection: ""))["selection"], .null)
        XCTAssertEqual(facts(terminal(selection: nil))["selection"], .null)
        XCTAssertEqual(facts(terminal(selection: "hi"))["selection"], "hi")
    }

    // MARK: - S6 the active board only

    func testS6OnlyTheCardsPassedAreReportedInTheirOrder() {
        XCTAssertEqual(cards(DevSnapshot.build(input(cards: [term()]))).map { $0["id"] }, ["t-1"])
        XCTAssertEqual(
            cards(DevSnapshot.build(input(cards: [doc(), term()]))).map { $0["id"] },
            ["/Users/e/a.b.md", "t-1"]
        )
    }

    // MARK: - S74 visibility is reported, not assumed

    func testS74VisibilityIsTheSuppliedState() {
        XCTAssertEqual(fields(DevSnapshot.build(input(visibility: .hidden)))["visibility"], "hidden")
        XCTAssertEqual(fields(DevSnapshot.build(input(visibility: .visible)))["visibility"], "visible")
    }

    /// Hidden is a window nobody can see — ordered out or in the Dock — and not
    /// one merely behind another app's, which still draws.
    func testS74AWindowOrderedOutOrMiniaturizedIsHidden() {
        XCTAssertEqual(DevSnapshot.Visibility(windowVisible: true, miniaturized: false), .visible)
        XCTAssertEqual(DevSnapshot.Visibility(windowVisible: false, miniaturized: false), .hidden)
        XCTAssertEqual(DevSnapshot.Visibility(windowVisible: true, miniaturized: true), .hidden)
        XCTAssertEqual(DevSnapshot.Visibility(windowVisible: false, miniaturized: true), .hidden)
    }

    // MARK: - S75 term.alive is live && !dead

    /// A dead card still draws and takes focus, then swallows every `type`.
    func testS75AHeldOpenDeadCardIsNotAlive() {
        XCTAssertEqual(facts(terminal(live: true, dead: false))["alive"], true)
        XCTAssertEqual(facts(terminal(live: true, dead: true))["alive"], false)
        XCTAssertEqual(facts(terminal(live: false, dead: false))["alive"], false)
        XCTAssertEqual(facts(terminal(live: false, dead: true))["alive"], false)
    }

    // MARK: - S76 ids are the bare wire ids

    func testS76TheSelectedCardIsFocusedCardAndTheOnlyFocusedOne() {
        let snapshot = DevSnapshot.build(input(selectedCard: "t-1"))
        XCTAssertEqual(cards(snapshot).map { $0["id"] }, ["t-1", "/Users/e/a.b.md"])
        XCTAssertEqual(fields(snapshot)["focused_card"], "t-1")
        XCTAssertEqual(card(snapshot, "t-1")["focused"], true)
        XCTAssertEqual(card(snapshot, "/Users/e/a.b.md")["focused"], false)
    }

    func testNothingSelectedIsANullFocusedCardAndNoFocusedCard() {
        let snapshot = DevSnapshot.build(input())
        XCTAssertEqual(fields(snapshot)["focused_card"], .null)
        XCTAssertEqual(cards(snapshot).map { $0["focused"] }, [false, false])
    }

    // MARK: - S7/S8 the projection agrees with the board transform

    func testS7TheProjectionMatchesWorldToViewAtBothCorners() {
        let rect = CGRect(x: 120, y: 60, width: 200, height: 100)
        let center = CGPoint(x: 500, y: 350)
        let viewportCenter = CGPoint(x: view.midX, y: view.midY)
        for zoom: CGFloat in [0.5, 1, 2.37] {
            let got = DevSnapshot.screenRect(of: rect, viewport: DevSnapshot.Viewport(zoom: zoom, center: center), viewRect: view)
            let topLeft = BoardTransform.worldToView(rect.origin, zoom: zoom, center: center, viewportCenter: viewportCenter)
            let bottomRight = BoardTransform.worldToView(
                CGPoint(x: rect.maxX, y: rect.maxY), zoom: zoom, center: center, viewportCenter: viewportCenter
            )
            XCTAssertEqual(got.minX, topLeft.x, accuracy: 1e-9)
            XCTAssertEqual(got.minY, topLeft.y, accuracy: 1e-9)
            XCTAssertEqual(got.width, bottomRight.x - topLeft.x, accuracy: 1e-9)
            XCTAssertEqual(got.height, bottomRight.y - topLeft.y, accuracy: 1e-9)
        }
    }

    /// Independent of `worldToView`, so a shared convention error cannot hide.
    /// View centre = (24 + 500, 40 + 350) = (524, 390); zoom 2.
    /// x = (120 − 500)·2 + 524 = −236; y = (60 − 350)·2 + 390 = −190.
    func testS7TheProjectionMatchesAHandComputedLiteral() {
        let got = DevSnapshot.screenRect(
            of: CGRect(x: 120, y: 60, width: 200, height: 100),
            viewport: DevSnapshot.Viewport(zoom: 2, center: CGPoint(x: 500, y: 350)),
            viewRect: view
        )
        XCTAssertEqual(got, CGRect(x: -236, y: -190, width: 400, height: 200))
    }

    func testS8AtZoomOneTheProjectionIsATranslationByTheViewOrigin() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 120)
        let viewport = DevSnapshot.Viewport(zoom: 1, center: CGPoint(x: view.width / 2, y: view.height / 2))
        XCTAssertEqual(
            DevSnapshot.screenRect(of: rect, viewport: viewport, viewRect: view),
            CGRect(x: rect.minX + view.minX, y: rect.minY + view.minY, width: rect.width, height: rect.height)
        )
    }

    /// The load-bearing row: at zoom 1 copying the size straight through passes.
    func testS8ZoomScalesTheSizeNotOnlyTheOrigin() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 120)
        let viewport = DevSnapshot.Viewport(zoom: 2.37, center: CGPoint(x: view.width / 2, y: view.height / 2))
        let got = DevSnapshot.screenRect(of: rect, viewport: viewport, viewRect: view)
        XCTAssertEqual(got.width, 474, accuracy: 1e-9)
        XCTAssertEqual(got.height, 284.4, accuracy: 1e-9)
    }

    // MARK: - S35 / S5 (2609.0018) the quit guard's facts

    private func quitGuard(
        phase: Guard.Phase = .showing, visible: Bool = true, alpha: Double = 0.5,
        lastPress: Guard.Press? = Guard.Press(pressMs: 5, route: .guard, ageMs: 3)
    ) -> Guard {
        Guard(
            retargeted: true, enabled: true, phase: phase, noticeVisible: visible, noticeAlpha: alpha, lastPress: lastPress
        )
    }

    func testS35TheGuardsFactsRideAlong() {
        XCTAssertEqual(fields(DevSnapshot.build(input(quitGuard: quitGuard())))["quit_guard"], [
            "retargeted": true,
            "enabled": true,
            "phase": "showing",
            "notice": ["visible": true, "alpha": 0.5],
            "last_press": ["press_ms": 5, "route": "guard", "age_ms": 3],
        ])
    }

    func testTheGuardsOtherStatesAreSpelledAsTheSuiteReadsThem() {
        let source = Guard(
            retargeted: false, enabled: false, phase: .confirming, noticeVisible: true, noticeAlpha: 1,
            lastPress: Guard.Press(pressMs: 123_456, route: .terminate, ageMs: -2)
        )
        XCTAssertEqual(fields(DevSnapshot.build(input(quitGuard: source)))["quit_guard"], [
            "retargeted": false,
            "enabled": false,
            "phase": "confirming",
            "notice": ["visible": true, "alpha": 1],
            "last_press": ["press_ms": 123_456, "route": "terminate", "age_ms": -2],
        ])
        XCTAssertEqual(Guard.Phase.idle.rawValue, "idle")
    }

    /// The toggle and the retarget are separate facts: `smoke.mjs` refuses to
    /// press ⌘Q unless BOTH read true, so one must not stand in for the other.
    func testTheToggleAndTheRetargetAreReportedSeparately() {
        func reported(retargeted: Bool, enabled: Bool) -> [String: JSONValue] {
            let source = Guard(
                retargeted: retargeted, enabled: enabled, phase: .idle, noticeVisible: false, noticeAlpha: 0, lastPress: nil
            )
            return fields(fields(DevSnapshot.build(input(quitGuard: source)))["quit_guard"])
        }
        let off = reported(retargeted: true, enabled: false)
        XCTAssertEqual(off["retargeted"], true)
        XCTAssertEqual(off["enabled"], false)
        let dropped = reported(retargeted: false, enabled: true)
        XCTAssertEqual(dropped["retargeted"], false)
        XCTAssertEqual(dropped["enabled"], true)
    }

    /// `quit.mjs`'s stale case reads the route off the app's `quit-key` log
    /// line, so the logged word and the reported one must stay one spelling.
    func testTheRouteTheGuardLogsIsTheOneReportedHere() {
        for route in [QuitGuard.Route.guarded, .terminateNow] {
            XCTAssertEqual(Guard.Route(route).rawValue, route.name)
        }
    }

    func testTheGuardsPhasesAndRoutesMapOntoTheReportedOnes() {
        XCTAssertEqual(Guard.Phase(QuitGuard.Phase.idle(lastStartMs: 7)), .idle)
        XCTAssertEqual(Guard.Phase(QuitGuard.Phase.showing(startedMs: 7)), .showing)
        XCTAssertEqual(Guard.Phase(QuitGuard.Phase.confirming), .confirming)
        XCTAssertEqual(Guard.Route(QuitGuard.Route.guarded), .guard)
        XCTAssertEqual(Guard.Route(QuitGuard.Route.terminateNow), .terminate)
    }

    /// Null rather than a missing key: `--until` reads a missing path as
    /// unresolvable, which would make `quit_guard.retargeted == true` a silent
    /// false instead of a fact.
    func testS35NoGuardIsNullAndNoPressIsNull() {
        XCTAssertEqual(fields(DevSnapshot.build(input(quitGuard: nil)))["quit_guard"], .null)
        let pressless = fields(fields(DevSnapshot.build(input(quitGuard: quitGuard(lastPress: nil))))["quit_guard"])
        XCTAssertEqual(pressless["last_press"], .null)
    }

    /// A hidden panel keeps whatever alpha it was left at — AppKit resets it to
    /// 1 — which would read as a notice at full opacity.
    func testS5AHiddenNoticeReadsAlphaZero() {
        let snapshot = DevSnapshot.build(input(quitGuard: quitGuard(phase: .idle, visible: false, alpha: 1)))
        XCTAssertEqual(fields(fields(snapshot)["quit_guard"])["notice"], ["visible": false, "alpha": 0])
    }

    /// After a tap's release the guard is idle while the notice still fades:
    /// `visible` is the discriminator, never `phase`.
    func testS5AVisibleNoticeKeepsItsAlphaWhileTheGuardIsIdle() {
        let snapshot = DevSnapshot.build(input(quitGuard: quitGuard(phase: .idle, visible: true, alpha: 0.3)))
        XCTAssertEqual(fields(fields(snapshot)["quit_guard"])["notice"], ["visible": true, "alpha": 0.3])
    }

    // MARK: - S9 (2609.0018) borrowed is a doc card's fact

    private func mixed() -> [Card] { [doc("/a/c.html"), doc("/a/b.md"), term()] }

    func testS9BorrowedIsTrueOnlyForTheBorrowedCardAndAbsentFromATerminal() {
        let snapshot = DevSnapshot.build(input(cards: mixed(), borrowedCard: "/a/c.html"))
        XCTAssertEqual(card(snapshot, "/a/c.html")["borrowed"], true)
        XCTAssertEqual(card(snapshot, "/a/b.md")["borrowed"], false)
        XCTAssertNil(card(snapshot, "t-1")["borrowed"])
    }

    func testS9BorrowedIsFalseOnEveryDocCardWhenNothingIs() {
        let snapshot = DevSnapshot.build(input(cards: mixed(), borrowedCard: nil))
        XCTAssertEqual(card(snapshot, "/a/c.html")["borrowed"], false)
        XCTAssertEqual(card(snapshot, "/a/b.md")["borrowed"], false)
    }

    // MARK: - active_element: native focus in the suite's DOM vocabulary

    private func activeElement(_ focus: DevSnapshot.KeyboardFocus) -> JSONValue? {
        fields(DevSnapshot.build(input(keyboardFocus: focus)))["active_element"]
    }

    /// `smoke.mjs` D8 reads `card` and `tag == "TEXTAREA"`; the class is xterm's
    /// own, which is what the Tauri driver reports there.
    func testAFocusedTerminalIsATextareaWithACaret() {
        XCTAssertEqual(activeElement(.terminal(card: "t-1", hasSelection: false)), [
            "card": "t-1", "tag": "TEXTAREA", "classes": ["xterm-helper-textarea"], "selection_type": "Caret",
        ])
    }

    /// `smoke.mjs` D5 fails the run unless a right-click leaves a `Range`.
    func testAFocusedTerminalWithASelectionIsARange() {
        XCTAssertEqual(activeElement(.terminal(card: "t-1", hasSelection: true)), [
            "card": "t-1", "tag": "TEXTAREA", "classes": ["xterm-helper-textarea"], "selection_type": "Range",
        ])
    }

    /// `smoke.mjs` D18 reads `tag == "IFRAME"` after `focus <html card>`.
    func testAFocusedHTMLDocumentIsAnIframe() {
        XCTAssertEqual(activeElement(.htmlDocument(card: "/a/c.html")), [
            "card": "/a/c.html", "tag": "IFRAME", "classes": ["html-frame"], "selection_type": "None",
        ])
    }

    /// `smoke.mjs` D8 reads `card == null` after `focus board`, and D17 reads
    /// `tag == "BODY"` after `focus <markdown card>`.
    func testNoCardHoldingFocusIsTheBody() {
        XCTAssertEqual(activeElement(.none), [
            "card": .null, "tag": "BODY", "classes": [], "selection_type": "None",
        ])
    }

    // MARK: - which card holds the keys

    private typealias Focus = DevSnapshot.KeyboardFocus

    private func focus(_ responder: DevSnapshot.KeyHolder?) -> Focus {
        Focus(responder: responder, switcherOwner: nil, switcherHoldsKeys: false)
    }

    func testATerminalHoldingFirstResponderHoldsTheKeys() {
        XCTAssertEqual(
            focus(.terminal(card: "t-1", hasSelection: true)), .terminal(card: "t-1", hasSelection: true)
        )
        XCTAssertEqual(
            focus(.terminal(card: "t-1", hasSelection: false)), .terminal(card: "t-1", hasSelection: false)
        )
    }

    /// Only an HTML card's document takes the keys; a markdown card is a
    /// reading surface, and focus inside one reads as the page body.
    func testADocCardHoldsTheKeysOnlyWhenItIsAnHTMLCard() {
        XCTAssertEqual(focus(.doc(path: "/a/c.html")), .htmlDocument(card: "/a/c.html"))
        XCTAssertEqual(focus(.doc(path: "/a/C.HTM")), .htmlDocument(card: "/a/C.HTM"))
        XCTAssertEqual(focus(.doc(path: "/a/b.md")), Focus.none)
        XCTAssertEqual(focus(nil), Focus.none)
    }

    /// The Tauri switcher never takes DOM focus — `activeElement` stays on the
    /// terminal behind it. The native one holds first responder while it is
    /// up, so the card reported is the one it hands the keys back to.
    func testWhileTheSwitcherHoldsTheKeysTheirOwnerIsTheCardBehindIt() {
        let terminal = DevSnapshot.KeyHolder.terminal(card: "t-1", hasSelection: false)
        XCTAssertEqual(
            Focus(responder: nil, switcherOwner: terminal, switcherHoldsKeys: true),
            .terminal(card: "t-1", hasSelection: false)
        )
        XCTAssertEqual(Focus(responder: nil, switcherOwner: nil, switcherHoldsKeys: true), Focus.none)
    }

    /// An owner left over from an earlier opening says nothing once the
    /// switcher has given the keys back.
    func testAClosedSwitchersOwnerIsIgnored() {
        let terminal = DevSnapshot.KeyHolder.terminal(card: "t-1", hasSelection: false)
        XCTAssertEqual(Focus(responder: nil, switcherOwner: terminal, switcherHoldsKeys: false), Focus.none)
        XCTAssertEqual(
            Focus(responder: .doc(path: "/a/c.html"), switcherOwner: terminal, switcherHoldsKeys: false),
            .htmlDocument(card: "/a/c.html")
        )
    }

    // MARK: - the order cards are reported in

    private typealias Ref = DevSnapshot.CardRef

    func testCardsAreTerminalsInCardOrderThenDocsAsTheBoardListsThem() {
        XCTAssertEqual(
            DevSnapshot.cardOrder(
                terminals: ["t-2", "t-1"], listedDocs: ["/z.md", "/a.md"],
                onBoard: [
                    Ref(kind: .doc, id: "/a.md"), Ref(kind: .term, id: "t-1"),
                    Ref(kind: .doc, id: "/z.md"), Ref(kind: .term, id: "t-2"),
                ]
            ),
            [
                Ref(kind: .term, id: "t-2"), Ref(kind: .term, id: "t-1"),
                Ref(kind: .doc, id: "/z.md"), Ref(kind: .doc, id: "/a.md"),
            ]
        )
    }

    /// The orders name cards from every source; only what has a card on the
    /// active board is reported.
    func testACardThatIsNotOnTheBoardIsLeftOut() {
        XCTAssertEqual(
            DevSnapshot.cardOrder(
                terminals: ["t-1", "t-gone"], listedDocs: ["/shelved.md", "/a.md"],
                onBoard: [Ref(kind: .term, id: "t-1"), Ref(kind: .doc, id: "/a.md")]
            ),
            [Ref(kind: .term, id: "t-1"), Ref(kind: .doc, id: "/a.md")]
        )
    }

    /// A card neither order names is still on the board, and still reported —
    /// last, terminals before docs, by id, so two snapshots agree.
    func testACardNoOrderNamesIsReportedLastInAStableOrder() {
        XCTAssertEqual(
            DevSnapshot.cardOrder(
                terminals: ["t-1"], listedDocs: ["/a.md"],
                onBoard: [
                    Ref(kind: .doc, id: "/y.md"), Ref(kind: .doc, id: "/a.md"), Ref(kind: .term, id: "t-9"),
                    Ref(kind: .doc, id: "/b.md"), Ref(kind: .term, id: "t-1"), Ref(kind: .term, id: "t-3"),
                ]
            ),
            [
                Ref(kind: .term, id: "t-1"), Ref(kind: .doc, id: "/a.md"),
                Ref(kind: .term, id: "t-3"), Ref(kind: .term, id: "t-9"),
                Ref(kind: .doc, id: "/b.md"), Ref(kind: .doc, id: "/y.md"),
            ]
        )
    }

    /// A term id and a doc path that spell the same are two cards.
    func testATerminalAndADocMayShareAnId() {
        XCTAssertEqual(
            DevSnapshot.cardOrder(
                terminals: ["x"], listedDocs: ["x"], onBoard: [Ref(kind: .term, id: "x"), Ref(kind: .doc, id: "x")]
            ),
            [Ref(kind: .term, id: "x"), Ref(kind: .doc, id: "x")]
        )
    }

    // MARK: - the replies built off a snapshot

    func testTheFocusReplyIsTheSelectionAndTheKeyboardFocus() {
        XCTAssertEqual(
            DevSnapshot.focusReply(selectedCard: "t-1", keyboardFocus: .terminal(card: "t-1", hasSelection: false)),
            [
                "focused_card": "t-1",
                "active_element": [
                    "card": "t-1", "tag": "TEXTAREA", "classes": ["xterm-helper-textarea"], "selection_type": "Caret",
                ],
            ]
        )
        XCTAssertEqual(
            DevSnapshot.focusReply(selectedCard: nil, keyboardFocus: .none).jsonString,
            #"{"active_element":{"card":null,"classes":[],"selection_type":"None","tag":"BODY"},"focused_card":null}"#
        )
    }

    /// Selection and keyboard focus disagree legitimately — a selected markdown
    /// card while a terminal still holds the keys — and each is reported as itself.
    func testTheFocusReplyKeepsTheSelectedCardApartFromTheOneHoldingTheKeys() {
        XCTAssertEqual(
            DevSnapshot.focusReply(selectedCard: "/a/b.md", keyboardFocus: .terminal(card: "t-1", hasSelection: false)),
            [
                "focused_card": "/a/b.md",
                "active_element": [
                    "card": "t-1", "tag": "TEXTAREA", "classes": ["xterm-helper-textarea"], "selection_type": "Caret",
                ],
            ]
        )
        XCTAssertEqual(
            DevSnapshot.focusReply(selectedCard: nil, keyboardFocus: .htmlDocument(card: "/a/c.html")),
            [
                "focused_card": .null,
                "active_element": ["card": "/a/c.html", "tag": "IFRAME", "classes": ["html-frame"], "selection_type": "None"],
            ]
        )
    }

    /// The same two facts the snapshot reports, so a reply and the snapshot taken
    /// after it cannot disagree.
    func testTheFocusReplyIsTheSnapshotsOwnTwoFields() {
        let source = input(selectedCard: "/Users/e/a.b.md", keyboardFocus: .htmlDocument(card: "/Users/e/a.b.md"))
        let snapshot = fields(DevSnapshot.build(source))
        XCTAssertEqual(
            DevSnapshot.focusReply(selectedCard: source.selectedCard, keyboardFocus: source.keyboardFocus),
            ["focused_card": snapshot["focused_card"] ?? "missing", "active_element": snapshot["active_element"] ?? "missing"]
        )
    }

    /// Routing's `not_focused` reads the same card the snapshot reports.
    func testTheCardHoldingKeyboardFocusIsTheOneActiveElementNames() {
        XCTAssertEqual(DevSnapshot.KeyboardFocus.terminal(card: "t-1", hasSelection: true).card, "t-1")
        XCTAssertEqual(DevSnapshot.KeyboardFocus.htmlDocument(card: "/a/c.html").card, "/a/c.html")
        XCTAssertNil(DevSnapshot.KeyboardFocus.none.card)
    }

    func testTheZoomReplyIsTheObservedZoom() {
        XCTAssertEqual(DevSnapshot.zoomReply(observed: 0.5).jsonString, #"{"zoom":0.5}"#)
        XCTAssertEqual(DevSnapshot.zoomReply(observed: 3).jsonString, #"{"zoom":3}"#)
    }

    // MARK: - what is sent is what `--until` evaluates

    func testUntilExpressionsResolveAgainstTheBuiltTree() throws {
        let snapshot = DevSnapshot.build(input(
            cards: [term(terminal(proc: "sleep", tail: "$ sleep 100")), doc()],
            quitGuard: quitGuard()
        ))
        for source in [
            "viewport.zoom == 1",
            "cards[t-1].board_rect.w ~= 400",
            #"cards[t-1].term.proc == "sleep""#,
            #"cards[t-1].term.scrollback_tail contains "sleep 100""#,
            "cards[/Users/e/a.b.md].borrowed == false",
            "cards[/Users/e/a.b.md].screen_rect == null",
            "quit_guard.retargeted == true",
            "quit_guard.last_press.press_ms ~= 5",
            #"quit_guard.phase == "showing""#,
        ] {
            XCTAssertTrue(DevUntil.evaluate(try DevUntil.parse(source), against: snapshot), source)
        }
    }

    func testTheTailLengthIsDefinedOnceHere() {
        XCTAssertEqual(DevSnapshot.scrollbackTailLines, 40)
    }

    /// 2610.0005 S13 — a role with nothing saved says `null`, so a reader can
    /// tell "the system default" from a key it failed to find. 2610.0006 S12 —
    /// Terminal and Document say their size; Interface has none.
    func testTheSnapshotReportsEachRolesSavedFamilyAndWhatItResolvedTo() {
        let fonts = DevSnapshot.Fonts(
            saved: [.terminal: "Menlo"], terminalFace: "Menlo-Regular", terminalSize: 16,
            interfaceFace: ".AppleSystemUIFontMonospaced-Regular", documentCSS: FontCSS.document(nil), documentSize: 14
        )
        XCTAssertEqual(
            fields(DevSnapshot.build(input(fonts: fonts)))["fonts"],
            [
                "terminal": ["saved": "Menlo", "face": "Menlo-Regular", "size": 16],
                "interface": ["saved": .null, "face": ".AppleSystemUIFontMonospaced-Regular"],
                "document": ["saved": .null, "css": #"-apple-system, "SF Pro Text", system-ui, sans-serif"#, "size": 14],
            ]
        )
        let all = DevSnapshot.Fonts(
            saved: [.terminal: "Monaco", .interface: "Menlo", .document: "Georgia"], terminalFace: "Monaco",
            terminalSize: 13.5, interfaceFace: "Menlo-Regular", documentCSS: FontCSS.document("Georgia"),
            documentSize: 18
        )
        XCTAssertEqual(
            fields(DevSnapshot.build(input(fonts: all)))["fonts"],
            [
                "terminal": ["saved": "Monaco", "face": "Monaco", "size": 13.5],
                "interface": ["saved": "Menlo", "face": "Menlo-Regular"],
                "document": [
                    "saved": "Georgia", "css": #""Georgia", -apple-system, "SF Pro Text", system-ui, sans-serif"#,
                    "size": 18,
                ],
            ]
        )
    }

    /// 2610.0007 S18 — the choice the app holds and the variant whose palette
    /// it holds are two facts: under Auto they are spelled apart. The key
    /// itself is in the list of `testS1TheSnapshotCarriesExactlyTheDocumentedTopLevelKeys`.
    func test2610_0007S18TheSnapshotReportsTheThemeChosenAndTheOneInEffect() {
        func theme(_ choice: ThemeChoice, _ inEffect: ThemeVariant) -> JSONValue? {
            fields(DevSnapshot.build(input(theme: DevSnapshot.Theme(choice: choice, inEffect: inEffect))))["theme"]
        }
        XCTAssertEqual(theme(.auto, .light), ["choice": "auto", "in_effect": "light"])
        XCTAssertEqual(theme(.auto, .dark), ["choice": "auto", "in_effect": "dark"])
        XCTAssertEqual(theme(.light, .light), ["choice": "light", "in_effect": "light"])
    }

    /// 2610.0007 — with nothing said the theme is the one of a file with no
    /// `theme` key: still an object with its two members.
    func test2610_0007AnInputGivenNoThemeReportsTheDarkOne() {
        XCTAssertEqual(fields(DevSnapshot.build(input()))["theme"], ["choice": "dark", "in_effect": "dark"])
    }

    func testTheSnapshotSerialisesAsCompactJSON() {
        let snapshot = DevSnapshot.build(input(cards: [doc("/a/b.md")]))
        XCTAssertEqual(
            snapshot.jsonString,
            #"{"active_element":{"card":null,"classes":[],"selection_type":"None","tag":"BODY"},"#
                + #""board_id":"board-0","#
                + #""cards":[{"board_rect":{"h":200,"w":300,"x":500,"y":20},"borrowed":false,"focused":false,"#
                + #""id":"/a/b.md","kind":"doc","screen_rect":null,"scroll":null}],"#
                + #""content_origin":null,"focused_card":null,"#
                + #""fonts":{"document":{"css":"system-ui","saved":null,"size":14},"#
                + #""interface":{"face":"SystemMono-Regular","saved":null},"#
                + #""terminal":{"face":"SystemMono-Regular","saved":null,"size":16}},"#
                + #""quit_guard":null,"theme":{"choice":"dark","in_effect":"dark"},"v":1,"#
                + #""viewport":{"cx":500,"cy":350,"view_rect":{"h":700,"w":1000,"x":24,"y":40},"zoom":1},"#
                + #""visibility":"visible"}"#
        )
    }
}
