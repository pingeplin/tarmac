import CoreGraphics
import XCTest
@testable import TarmacKit

/// What each QA-driver verb acts on, and which preconditions are checked before
/// anything is injected (spec 2609.0015, #166; doc focus from 2609.0018).
final class DevRoutingTests: XCTestCase {
    private typealias Card = DevRouting.Card
    private typealias Route = DevRouting.Route

    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// Only the ACTIVE board's cards: another board's are deliberately not
    /// addressable.
    private func context(
        cards: [Card]? = nil, keyboardFocus: String? = nil, borrowed: String? = nil
    ) -> DevRouting.Context {
        DevRouting.Context(
            cards: cards ?? [
                Card(id: "t-1", kind: .term, frame: unit),
                Card(id: "/a/b.md", kind: .doc, frame: unit),
            ],
            keyboardFocusCard: keyboardFocus,
            borrowedCard: borrowed,
            zoom: 1,
            center: .zero,
            viewSize: CGSize(width: 1000, height: 800)
        )
    }

    private func docs(html: CGRect? = nil, markdown: CGRect? = nil, borrowed: String? = nil) -> DevRouting.Context {
        context(cards: [
            Card(id: "t-1", kind: .term, frame: frame),
            Card(id: "/a/b.md", kind: .doc, frame: markdown ?? frame),
            Card(id: "/a/c.html", kind: .doc, frame: html ?? frame),
            Card(id: "/a/C.HTM", kind: .doc, frame: frame),
        ], borrowed: borrowed)
    }

    private func route(_ request: DevRequest, _ context: DevRouting.Context? = nil) -> Route {
        DevRouting.route(request, in: context ?? self.context())
    }

    private func refusal(
        _ request: DevRequest, _ context: DevRouting.Context? = nil, file: StaticString = #filePath, line: UInt = #line
    ) -> DevError? {
        guard case .refused(let error) = route(request, context) else {
            XCTFail("\(request) was not refused: \(route(request, context))", file: file, line: line)
            return nil
        }
        return error
    }

    // MARK: - verbs that need no card

    func testS42ZoomIsTheViewportCommitWithNoTarget() {
        XCTAssertEqual(route(.zoom(z: 0.5)), .zoom(0.5))
        XCTAssertEqual(route(.zoom(z: 99), context(cards: [])), .zoom(99))
    }

    func testS36FocusWithNoCardIsThePressOnTheEmptyBoard() {
        XCTAssertEqual(route(.focus(card: nil)), .focusBoard)
        XCTAssertEqual(route(.focus(card: nil), context(cards: [])), .focusBoard)
    }

    /// `snapshot` reads state and `press` posts a chord to the window: neither
    /// has a card, so neither has a precondition here.
    func testSnapshotAndPressPassStraightThrough() {
        XCTAssertEqual(
            route(.snapshot(until: "viewport.zoom == 1", timeoutMs: 300), context(cards: [])),
            .snapshot(until: "viewport.zoom == 1", timeoutMs: 300)
        )
        XCTAssertEqual(route(.snapshot(until: nil, timeoutMs: nil)), .snapshot(until: nil, timeoutMs: nil))
        XCTAssertEqual(
            route(.press(combo: "cmd+q", holdMs: 300, ageMs: 5, busyMs: 7), context(cards: [])),
            .press(combo: "cmd+q", holdMs: 300, ageMs: 5, busyMs: 7)
        )
    }

    /// A newer CLI meeting this app: saying which verbs exist is more use than a
    /// routing error that blames the spelling of a card.
    func testAVerbThisBuildDoesNotKnowIsUnsupportedVerb() {
        let error = refusal(.unknown(type: "pan"))
        XCTAssertEqual(error?.code, .unsupportedVerb)
        XCTAssertEqual(error?.message.contains("`pan`"), true)
        XCTAssertEqual(error?.message.contains("snapshot, zoom, focus, resize, type, key, press"), true)
    }

    // MARK: - S35 focus <term>

    func testS35FocusOnATerminalIsThePressOnItsBody() {
        XCTAssertEqual(route(.focus(card: "t-1")), .focusTerminal(card: "t-1"))
    }

    // MARK: - S37 type and key

    func testS37TypeAndKeyGoToTheFocusedTerminal() {
        let focused = context(keyboardFocus: "t-1")
        XCTAssertEqual(route(.type(card: "t-1", text: "hi"), focused), .type(card: "t-1", text: "hi"))
        guard case .key(card: "t-1", combo: "ctrl+c", let stroke) = route(.key(card: "t-1", combo: "ctrl+c"), focused) else {
            return XCTFail("ctrl+c did not route to a key stroke")
        }
        XCTAssertEqual(DevKeyCombo.parse("ctrl+c"), .stroke(stroke))
    }

    /// A right-click is a mouse action on the terminal's grid, not a key: routing
    /// it as one would leave a caret where the scenario needs a Range.
    func testS37ContextMenuIsARightClickNotAKey() {
        XCTAssertEqual(
            route(.key(card: "t-1", combo: "contextmenu"), context(keyboardFocus: "t-1")),
            .contextMenu(card: "t-1")
        )
    }

    // MARK: - S38 resize

    func testS38ResizeDragsTheCardFromItsCurrentSizeToTheRequestedOne() {
        XCTAssertEqual(
            route(.resize(card: "t-1", w: 800, h: 600), docs()),
            .resize(card: "t-1", from: CGSize(width: 400, height: 300), to: CGSize(width: 800, height: 600))
        )
    }

    // MARK: - S76 the wire speaks bare ids

    /// The Tauri app's internal `term:`/`doc:` prefix is not an alias here: an id
    /// is the term id or the doc's path, or it names no card.
    func testS76ABareIdResolvesAndAPrefixedOneDoesNot() {
        XCTAssertEqual(route(.focus(card: "t-1")), .focusTerminal(card: "t-1"))
        XCTAssertEqual(refusal(.focus(card: "term:t-1"))?.code, .noSuchCard)
        XCTAssertEqual(refusal(.focus(card: "doc:/a/b.md"), docs())?.code, .noSuchCard)
    }

    // MARK: - S39 an unknown card

    func testS39AnUnknownCardIsRefusedForEveryVerbThatTakesOne() {
        let requests: [DevRequest] = [
            .focus(card: "t-9"),
            .type(card: "t-9", text: "x"),
            .key(card: "t-9", combo: "enter"),
            .resize(card: "t-9", w: 1, h: 1),
        ]
        for request in requests {
            let error = refusal(request)
            XCTAssertEqual(error?.code, .noSuchCard, "\(request)")
            XCTAssertEqual(error?.extra, ["card": "t-9"], "\(request)")
        }
    }

    func testS39ACardOnAnotherBoardIsRefusedTheSameWay() {
        XCTAssertEqual(refusal(.focus(card: "t-on-another-board"))?.code, .noSuchCard)
    }

    // MARK: - S40 type/key require focus to already be right

    /// A passing verb proves focus rather than establishing it.
    func testS40TypeAndKeyAreRefusedWhenKeyboardFocusIsElsewhere() {
        let requests: [DevRequest] = [.type(card: "t-1", text: "x"), .key(card: "t-1", combo: "enter")]
        for request in requests {
            for focus in [nil, "/a/b.md", "t-2"] {
                let error = refusal(request, context(keyboardFocus: focus))
                XCTAssertEqual(error?.code, .notFocused, "\(request) with focus on \(focus ?? "nothing")")
                XCTAssertEqual(error?.extra, ["card": "t-1"])
            }
        }
    }

    /// The precondition outranks the argument: a caller fixing both gets one
    /// error at a time, in that order.
    func testS40FocusIsCheckedBeforeTheComboIsParsed() {
        XCTAssertEqual(refusal(.key(card: "t-1", combo: "frobnicate"))?.code, .notFocused)
        XCTAssertEqual(refusal(.key(card: "t-1", combo: "contextmenu"))?.code, .notFocused)
        XCTAssertEqual(refusal(.key(card: "t-1", combo: "cmd+c"))?.code, .notFocused)
    }

    func testAFocusedTerminalStillRefusesAComboOutsideTheGrammar() {
        let focused = context(keyboardFocus: "t-1")
        let bad = refusal(.key(card: "t-1", combo: "frobnicate"), focused)
        XCTAssertEqual(bad?.code, .badCombo)
        XCTAssertEqual(bad?.extra, ["combo": "frobnicate"])
        XCTAssertEqual(refusal(.key(card: "t-1", combo: "cmd+c"), focused)?.code, .unsupportedCombo)
        XCTAssertEqual(refusal(.key(card: "t-1", combo: "a"), focused)?.code, .unsupportedCombo)
    }

    // MARK: - S41 doc cards take focus, but cannot be typed into or keyed

    func testS41TypeAndKeyOnADocCardAreUnsupportedCardKind() {
        let requests: [DevRequest] = [.type(card: "/a/b.md", text: "x"), .key(card: "/a/b.md", combo: "enter")]
        for request in requests {
            let error = refusal(request)
            XCTAssertEqual(error?.code, .unsupportedCardKind, "\(request)")
            XCTAssertEqual(error?.extra, ["card": "/a/b.md"])
        }
    }

    /// A doc card can legitimately hold keyboard focus, so checking focus first
    /// would make the error depend on where focus happens to be, which is not a
    /// property of the request.
    func testS41TheKindIsCheckedBeforeTheFocusPrecondition() {
        XCTAssertEqual(
            refusal(.type(card: "/a/b.md", text: "x"), context(keyboardFocus: "/a/b.md"))?.code,
            .unsupportedCardKind
        )
        XCTAssertEqual(
            refusal(.key(card: "/a/b.md", combo: "frobnicate"), context(keyboardFocus: "/a/b.md"))?.code,
            .unsupportedCardKind
        )
    }

    func testS41ADocCardStillResizes() {
        XCTAssertEqual(
            route(.resize(card: "/a/b.md", w: 1, h: 2)),
            .resize(card: "/a/b.md", from: CGSize(width: 1, height: 1), to: CGSize(width: 1, height: 2))
        )
    }

    // MARK: - S8 (2609.0018) focus on a doc card, per kind

    func testS8AMarkdownCardIsSelectedAndKeyboardFocusDropped() {
        XCTAssertEqual(route(.focus(card: "/a/b.md"), docs()), .focusMarkdown(card: "/a/b.md"))
    }

    func testS8AnHTMLCardIsSelectedBorrowedAndItsDocumentFocused() {
        XCTAssertEqual(route(.focus(card: "/a/c.html"), docs()), .focusHTML(card: "/a/c.html", borrow: true))
    }

    func testS8TheExtensionDecidesTheKindIgnoringCase() {
        XCTAssertEqual(route(.focus(card: "/a/C.HTM"), docs()), .focusHTML(card: "/a/C.HTM", borrow: true))
    }

    /// The borrow gesture on a card that is already borrowed would land inside
    /// its document, so the route says whether it is still owed.
    func testS8AnAlreadyBorrowedCardIsNotBorrowedAgain() {
        XCTAssertEqual(
            route(.focus(card: "/a/c.html"), docs(borrowed: "/a/c.html")),
            .focusHTML(card: "/a/c.html", borrow: false)
        )
        XCTAssertEqual(
            route(.focus(card: "/a/c.html"), docs(borrowed: "/a/C.HTM")),
            .focusHTML(card: "/a/c.html", borrow: true)
        )
    }

    /// Kept region for this context: x in (−1500, 1500), y in (−1200, 1200).
    func testS8ACulledHTMLCardIsCardHidden() {
        let far = CGRect(x: 10_000, y: 0, width: 400, height: 300)
        let error = refusal(.focus(card: "/a/c.html"), docs(html: far))
        XCTAssertEqual(error?.code, .cardHidden)
        XCTAssertEqual(error?.extra, ["card": "/a/c.html"])
    }

    /// Inside ±1500 but outside ±1200 and ±500: the predicate is the one the
    /// board culls with — width and height not swapped, one-viewport margin kept.
    func testS8AnHTMLCardInTheCullMarginStillTakesFocus() {
        let edge = CGRect(x: 1300, y: 0, width: 400, height: 300)
        XCTAssertEqual(route(.focus(card: "/a/c.html"), docs(html: edge)), .focusHTML(card: "/a/c.html", borrow: true))
        let below = CGRect(x: 0, y: 1300, width: 400, height: 300)
        XCTAssertEqual(refusal(.focus(card: "/a/c.html"), docs(html: below))?.code, .cardHidden)
    }

    /// The kept region is the board's own: it widens as the board zooms out and
    /// follows the viewport's centre, so `zoom` can bring a refused card back.
    func testS8TheCullFollowsTheViewportsZoomAndCentre() {
        let cards = [Card(id: "/a/c.html", kind: .doc, frame: CGRect(x: 2500, y: 0, width: 400, height: 300))]
        func context(zoom: CGFloat, center: CGPoint) -> DevRouting.Context {
            DevRouting.Context(
                cards: cards, keyboardFocusCard: nil, borrowedCard: nil,
                zoom: zoom, center: center, viewSize: CGSize(width: 1000, height: 800)
            )
        }
        let focus = DevRequest.focus(card: "/a/c.html")
        XCTAssertEqual(refusal(focus, context(zoom: 1, center: .zero))?.code, .cardHidden)
        XCTAssertEqual(route(focus, context(zoom: 0.5, center: .zero)), .focusHTML(card: "/a/c.html", borrow: true))
        XCTAssertEqual(
            route(focus, context(zoom: 1, center: CGPoint(x: 2500, y: 0))),
            .focusHTML(card: "/a/c.html", borrow: true)
        )
        XCTAssertEqual(refusal(focus, context(zoom: 1, center: CGPoint(x: 0, y: 2500)))?.code, .cardHidden)
    }

    func testS8CardHiddenIsFocusOnAnHTMLCardAndNothingElse() {
        let far = CGRect(x: 10_000, y: 0, width: 400, height: 300)
        XCTAssertEqual(route(.focus(card: "/a/b.md"), docs(markdown: far)), .focusMarkdown(card: "/a/b.md"))
        XCTAssertEqual(
            route(.focus(card: "t-1"), context(cards: [Card(id: "t-1", kind: .term, frame: far)])),
            .focusTerminal(card: "t-1")
        )
        XCTAssertEqual(refusal(.type(card: "/a/c.html", text: "x"), docs(html: far))?.code, .unsupportedCardKind)
        XCTAssertEqual(refusal(.key(card: "/a/c.html", combo: "enter"), docs(html: far))?.code, .unsupportedCardKind)
        XCTAssertEqual(
            route(.resize(card: "/a/c.html", w: 1, h: 1), docs(html: far)),
            .resize(card: "/a/c.html", from: far.size, to: CGSize(width: 1, height: 1))
        )
    }

    func testS8TypeAndKeyAreRefusedOnEitherDocKind() {
        for card in ["/a/b.md", "/a/c.html"] {
            XCTAssertEqual(refusal(.type(card: card, text: "x"), docs())?.code, .unsupportedCardKind, card)
            XCTAssertEqual(refusal(.key(card: card, combo: "enter"), docs())?.code, .unsupportedCardKind, card)
        }
    }

    // MARK: - messages

    func testEachRoutingRefusalSaysWhatWouldFixIt() {
        XCTAssertEqual(refusal(.focus(card: "t-9"))?.message, "no card with that id on the active board")
        XCTAssertEqual(
            refusal(.type(card: "t-1", text: "x"))?.message,
            "that card does not hold keyboard focus; `tarmac dev focus <card>` first"
        )
        XCTAssertEqual(
            refusal(.type(card: "/a/b.md", text: "x"))?.message,
            "doc cards take `focus`, but cannot be typed into or keyed"
        )
        let far = CGRect(x: 10_000, y: 0, width: 400, height: 300)
        XCTAssertEqual(refusal(.focus(card: "/a/c.html"), docs(html: far))?.message.contains("zoom out"), true)
    }
}
