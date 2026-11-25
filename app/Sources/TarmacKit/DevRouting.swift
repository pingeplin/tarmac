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
///   - `card_hidden` is `focus` on an HTML card, or `click` on a culled card:
///     its view is hidden and cannot take focus or a press. The predicate is the
///     one the board culls with, so the refusal and the paint agree.
///
/// `click` (2611.0015 D16) has an order of its own; see `click(_:_:in:)`.
public enum DevRouting {
    public struct Card: Equatable, Sendable {
        /// The bare wire id: a term id, or a doc's absolute path.
        public var id: String
        public var kind: DevCardKind
        public var frame: CGRect
        /// The `click` controls the card shows now, from the models that draw them.
        public var controls: [DevClick.Control]

        public init(id: String, kind: DevCardKind, frame: CGRect, controls: [DevClick.Control] = []) {
            self.id = id
            self.kind = kind
            self.frame = frame
            self.controls = controls
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
        public var activeBoardID: String
        /// Every board the app knows, as the daemon's last `board_list` named them.
        public var boardIDs: [String]
        /// The restore card's choices while it is up; nil while it is not.
        public var restoreCard: [RestoreCard.Choice.Action]?

        public init(
            cards: [Card], keyboardFocusCard: String?, borrowedCard: String?, zoom: CGFloat, center: CGPoint,
            viewSize: CGSize,
            activeBoardID: String, boardIDs: [String], restoreCard: [RestoreCard.Choice.Action]? = nil
        ) {
            self.restoreCard = restoreCard
            self.activeBoardID = activeBoardID
            self.boardIDs = boardIDs
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
        case press(combo: String, holdMs: Int?, ageMs: Int?, busyMs: Int?, repeats: Int?)
        /// Committed through the board's own viewport commit, not an event.
        case zoom(Double)
        /// A press on the empty board, which clears selection and keyboard focus.
        case focusBoard
        /// A press on the card's body: select, prime, keyboard focus. A culled
        /// terminal is selected and nothing more (`takesKeys` false): its view
        /// is hidden, and the keys stay where they were. The Tauri driver does
        /// not refuse it either — there the hidden text area ignores `focus()`.
        case focusTerminal(card: String, takesKeys: Bool)
        /// Select the card and take keyboard focus off any terminal.
        case focusMarkdown(card: String)
        /// Select the card and focus its document, first borrowing it if `borrow`.
        case focusHTML(card: String, borrow: Bool)
        /// Drag `handle` (`DevResizeGrip`); `from` is the card's
        /// world size now. The press on the handle selects the card like any
        /// press on it, and on a culled card leaves the keys where they were
        /// (`takesKeys` false), as `focusTerminal` does.
        case resize(card: String, from: CGSize, to: CGSize, takesKeys: Bool, handle: CardResize.Handle = .bottomRight)
        /// Deliver `text` to the terminal (`DevTypePlan`).
        case type(card: String, text: String)
        case key(card: String, combo: String, stroke: DevKeyStroke)
        /// Right-click the terminal's last written cell (`DevCellPoint`).
        case contextMenu(card: String)
        /// Already the active board: nothing is sent, and the answer names it.
        case activeBoard(String)
        case switchBoard(to: String)
        case createBoard(from: String)
        /// Press and release `control` of the card, or of the restore card
        /// when `card` is nil.
        case click(card: String?, control: DevClick.Control)
        case refused(DevError)
    }

    /// The verbs this build answers, for a newer CLI that sends another.
    public static let implementedVerbs = [
        "snapshot", "zoom", "focus", "resize", "type", "key", "press", "board", "click",
    ]

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
        case .press(let combo, let holdMs, let ageMs, let busyMs, let repeats):
            return .press(combo: combo, holdMs: holdMs, ageMs: ageMs, busyMs: busyMs, repeats: repeats)
        case .unknown(let type):
            return .refused(unsupportedVerb(type))
        case .click(let card, let control):
            return click(card, control, in: context)
        case .board(nil):
            return .createBoard(from: context.activeBoardID)
        case .board(let id?):
            if id == context.activeBoardID { return .activeBoard(id) }
            guard context.boardIDs.contains(id) else {
                return .refused(
                    DevError(
                        .noSuchBoard, "the app knows no board with that id",
                        extra: ["board_id": .string(id), "boards": .array(context.boardIDs.map(JSONValue.string))]
                    ))
            }
            return .switchBoard(to: id)
        case .zoom(let z):
            return .zoom(z)
        case .focus(nil):
            return .focusBoard
        case .focus(let id?):
            return onCard(id, in: context) { card in
                guard card.kind == .doc else {
                    return .focusTerminal(card: id, takesKeys: isVisible(card, in: context))
                }
                return focusDoc(card, in: context)
            }
        case .resize(let id, let w, let h, let name):
            guard let handle = name.map(DevResizeGrip.handle(named:)) ?? .bottomRight else {
                return .refused(DevError(.badRequest, "no resize handle is named `\(name ?? "")`"))
            }
            return onCard(id, in: context) { card in
                .resize(
                    card: id, from: card.frame.size, to: CGSize(width: w, height: h),
                    takesKeys: isVisible(card, in: context), handle: handle
                )
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

    /// The name first: it is a property of the request, so it comes before any
    /// look-up. A modal restore card covers every card control, present or
    /// not. An absent control is a fact no zoom changes, so it comes before
    /// `card_hidden`.
    private static func click(_ id: String?, _ name: String, in context: Context) -> Route {
        let names = DevClick.controls(of: id == nil ? .restoreCard : .card)
        guard let control = DevClick.Control(rawValue: name), names.contains(control) else {
            let set = names.map(\.rawValue).joined(separator: ", ")
            let target = id == nil ? "the restore card" : "a card"
            return .refused(DevError(.badRequest, "\(target) has no control `\(name)`; it has \(set)"))
        }
        guard let id else {
            let present = context.restoreCard.map(DevClick.present(restoreChoices:)) ?? []
            guard present.contains(control) else { return noSuchControl(card: nil, control, present: present) }
            return .click(card: nil, control: control)
        }
        return onCard(id, in: context) { card in
            guard card.kind == .term else {
                return refused(.unsupportedCardKind, "only a terminal card has these controls", card: id)
            }
            guard context.restoreCard == nil else {
                return .refused(
                    DevError(
                        .controlCovered, "the restore card covers every card; click one of its controls first",
                        extra: ["card": .string(id), "control": .string(name)]
                    ))
            }
            guard card.controls.contains(control) else {
                return noSuchControl(card: id, control, present: card.controls)
            }
            guard isVisible(card, in: context) else {
                return refused(
                    .cardHidden, "that card is culled off-screen and its controls are hidden; zoom out", card: id)
            }
            return .click(card: id, control: control)
        }
    }

    private static func noSuchControl(card: String?, _ control: DevClick.Control, present: [DevClick.Control]) -> Route
    {
        .refused(
            DevError(
                .noSuchControl, "that control is not showing now",
                extra: [
                    "card": card.map(JSONValue.string) ?? .null, "control": .string(control.rawValue),
                    "present": .array(present.map { .string($0.rawValue) }),
                ]
            ))
    }

    private static func onCard(_ id: String, in context: Context, _ then: (Card) -> Route) -> Route {
        guard let card = context.cards.first(where: { DocPath($0.id) == DocPath(id) }) else {
            return refused(.noSuchCard, "no card with that id on the active board", card: id)
        }
        return then(card)
    }

    private static func onFocusedTerminal(_ id: String, in context: Context, _ then: () -> Route) -> Route {
        onCard(id, in: context) { card in
            guard card.kind == .term else {
                return refused(
                    .unsupportedCardKind, "doc cards take `focus`, but cannot be typed into or keyed", card: id)
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
        guard isVisible(card, in: context) else {
            return refused(
                .cardHidden,
                "that HTML card is culled off-screen and its document cannot take focus; "
                    + "zoom out (or pan by hand — no verb pans)",
                card: card.id
            )
        }
        return .focusHTML(card: card.id, borrow: context.borrowedCard.map(DocPath.init) != DocPath(card.id))
    }

    /// Not culled: the predicate the board hides cards with.
    private static func isVisible(_ card: Card, in context: Context) -> Bool {
        Cull.isCardVisible(frame: card.frame, zoom: context.zoom, center: context.center, viewSize: context.viewSize)
    }

    private static func refused(_ code: DevError.Code, _ message: String, card: String) -> Route {
        .refused(DevError(code, message, extra: ["card": .string(card)]))
    }
}
