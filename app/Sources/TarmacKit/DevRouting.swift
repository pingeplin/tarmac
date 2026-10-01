import CoreGraphics
import Foundation

/// What each QA-driver verb acts on, and which preconditions are checked before
/// anything is injected (spec 2609.0015, issue #166; doc focus from 2609.0018).
///
/// The routing is a decision, not wiring, because getting it wrong produces a
/// scenario that passes while testing the wrong thing. The order is the contract:
///   - the card must exist on the ACTIVE board (`no_such_card`);
///   - `resize` then needs nothing else — any kind of card resizes;
///   - the card KIND is checked before focus (`unsupported_card_kind`), so the
///     error names a property of the request rather than of wherever focus
///     happened to be;
///   - `type`/`key` need keyboard focus to ALREADY be on the card
///     (`not_focused`), so a passing verb proves focus rather than establishing
///     it — and that is checked before the combo is parsed, so a caller fixing
///     both gets one error at a time;
///   - `card_hidden` is `focus` on an HTML card alone: a culled card's web view
///     is hidden and cannot take focus. The predicate is the one the board culls
///     with, so the refusal and the paint agree.
public enum DevRouting {
    public struct Card: Equatable, Sendable {
        /// The bare wire id: a term id, or a doc's absolute path.
        public var id: String
        public var kind: DevCardKind
        public var frame: CGRect

        public init(id: String, kind: DevCardKind, frame: CGRect) {
            self.id = id
            self.kind = kind
            self.frame = frame
        }
    }

    public struct Context: Equatable, Sendable {
        /// The ACTIVE board's cards only. Another board's cards are not on
        /// screen, so driving one would produce events no snapshot could
        /// observe; they are absent here, and so are `no_such_card`.
        public var cards: [Card]
        /// The card holding keyboard focus, if any.
        public var keyboardFocusCard: String?
        /// The HTML card whose document takes input, if any.
        public var borrowedCard: String?
        public var zoom: CGFloat
        public var center: CGPoint
        public var viewSize: CGSize

        public init(
            cards: [Card], keyboardFocusCard: String?, borrowedCard: String?, zoom: CGFloat, center: CGPoint, viewSize: CGSize
        ) {
            self.cards = cards
            self.keyboardFocusCard = keyboardFocusCard
            self.borrowedCard = borrowedCard
            self.zoom = zoom
            self.center = center
            self.viewSize = viewSize
        }
    }

    public enum Route: Equatable, Sendable {
        /// Reads state and injects nothing.
        case snapshot(until: String?, timeoutMs: Int?)
        /// A native ⌘ chord posted to the window; no card is involved.
        case press(combo: String, holdMs: Int?, ageMs: Int?, busyMs: Int?)
        /// Committed through the board's own viewport commit, not an event.
        case zoom(Double)
        /// A press on the empty board, which clears selection and keyboard focus.
        case focusBoard
        /// A press on the card's body: select, prime, keyboard focus.
        case focusTerminal(card: String)
        /// Select the card and take keyboard focus off any terminal.
        case focusMarkdown(card: String)
        /// Select the card and focus its document, first borrowing it if `borrow`.
        case focusHTML(card: String, borrow: Bool)
        /// Drag the bottom-right handle (`DevResizeGrip`); `from` is the card's
        /// world size now.
        case resize(card: String, from: CGSize, to: CGSize)
        /// Deliver `text` to the terminal (`DevTypePlan`).
        case type(card: String, text: String)
        case key(card: String, combo: String, stroke: DevKeyStroke)
        /// Right-click the terminal's last written cell (`DevCellPoint`).
        case contextMenu(card: String)
        case refused(DevError)
    }

    /// The verbs this build answers, for a newer CLI that sends another.
    public static let implementedVerbs = ["snapshot", "zoom", "focus", "resize", "type", "key", "press"]

    /// Saying which verbs exist is more use to a newer CLI than naming the verb
    /// it sent back at it.
    public static func unsupportedVerb(_ type: String) -> DevError {
        DevError(
            .unsupportedVerb,
            "this app does not implement `\(type)`; it has \(implementedVerbs.joined(separator: ", "))"
        )
    }

    public static func route(_ request: DevRequest, in context: Context) -> Route {
        switch request {
        case .snapshot(let until, let timeoutMs):
            return .snapshot(until: until, timeoutMs: timeoutMs)
        case .press(let combo, let holdMs, let ageMs, let busyMs):
            return .press(combo: combo, holdMs: holdMs, ageMs: ageMs, busyMs: busyMs)
        case .unknown(let type):
            return .refused(unsupportedVerb(type))
        case .zoom(let z):
            return .zoom(z)
        case .focus(nil):
            return .focusBoard
        case .focus(let id?):
            return onCard(id, in: context) { card in
                guard card.kind == .doc else { return .focusTerminal(card: id) }
                return focusDoc(card, in: context)
            }
        case .resize(let id, let w, let h):
            return onCard(id, in: context) { card in
                .resize(card: id, from: card.frame.size, to: CGSize(width: w, height: h))
            }
        case .type(let id, let text):
            return onFocusedTerminal(id, in: context) { .type(card: id, text: text) }
        case .key(let id, let combo):
            return onFocusedTerminal(id, in: context) {
                switch DevKeyCombo.parse(combo) {
                case .stroke(let stroke): .key(card: id, combo: combo, stroke: stroke)
                case .contextMenu: .contextMenu(card: id)
                case .refused(let error): .refused(error)
                }
            }
        }
    }

    private static func onCard(_ id: String, in context: Context, _ then: (Card) -> Route) -> Route {
        guard let card = context.cards.first(where: { $0.id == id }) else {
            return refused(.noSuchCard, "no card with that id on the active board", card: id)
        }
        return then(card)
    }

    private static func onFocusedTerminal(_ id: String, in context: Context, _ then: () -> Route) -> Route {
        onCard(id, in: context) { card in
            guard card.kind == .term else {
                return refused(.unsupportedCardKind, "doc cards take `focus`, but cannot be typed into or keyed", card: id)
            }
            guard context.keyboardFocusCard == id else {
                return refused(
                    .notFocused, "that card does not hold keyboard focus; `tarmac dev focus <card>` first", card: id
                )
            }
            return then()
        }
    }

    private static func focusDoc(_ card: Card, in context: Context) -> Route {
        guard DocKind(path: card.id) == .html else { return .focusMarkdown(card: card.id) }
        guard Cull.isCardVisible(frame: card.frame, zoom: context.zoom, center: context.center, viewSize: context.viewSize)
        else {
            return refused(
                .cardHidden,
                "that HTML card is culled off-screen and its document cannot take focus; "
                    + "zoom out (or pan by hand — no verb pans)",
                card: card.id
            )
        }
        return .focusHTML(card: card.id, borrow: context.borrowedCard != card.id)
    }

    private static func refused(_ code: DevError.Code, _ message: String, card: String) -> Route {
        .refused(DevError(code, message, extra: ["card": .string(card)]))
    }
}
