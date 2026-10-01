import CoreGraphics
import Foundation

/// The two card kinds as the QA driver's wire names them.
public enum DevCardKind: String, Equatable, Sendable {
    case term, doc
}

/// The QA driver's snapshot (spec 2609.0015, issue #166): the app's live UI
/// state as a JSON tree, so an outside process can read rects, focus, selection
/// and terminal facts that exist nowhere but inside the window. `build` returns
/// the tree that is both sent (`jsonString`) and evaluated (`DevUntil`), so an
/// `--until` can never hold on something other than what the caller receives.
///
/// Pure by construction: every measured fact arrives by argument. Three rules
/// the views must not re-decide:
///   - ids are the BARE wire ids — a term id, or a doc's absolute path;
///   - `screen_rect` is what the card's view measured, or null — never the
///     projection of `board_rect`, which exists so a scenario can compare the two;
///   - an absent fact is null (or, for a doc card's `term`, no key at all), never
///     an empty string or a default.
///
/// Rects are top-left-origin: `view_rect` and `screen_rect` in the window's
/// content coordinates, `board_rect` in world units.
public enum DevSnapshot {
    /// How many rows of context `scrollback_tail` carries: the 40 ending at the
    /// cursor's row, not the last 40 of the buffer — on a tall card with little
    /// output those are all blank. The terminal view reads that window itself;
    /// this is the one definition of its length.
    public static let scrollbackTailLines = 40

    public enum Visibility: String, Equatable, Sendable {
        case visible, hidden
    }

    public struct Viewport: Equatable, Sendable {
        public var zoom: CGFloat
        /// The world point at the middle of the board view.
        public var center: CGPoint

        public init(zoom: CGFloat, center: CGPoint) {
            self.zoom = zoom
            self.center = center
        }
    }

    /// What the app measured off one terminal card.
    public struct Terminal: Equatable, Sendable {
        public var live: Bool
        public var dead: Bool
        public var cols: Int
        public var rows: Int
        /// The daemon's last `term_proc` name; nil when it has never reported one.
        public var proc: String?
        /// The selected text, verbatim; `build` normalises "none" to null.
        public var selection: String?
        /// The `scrollbackTailLines` rows ending at the cursor's row.
        public var scrollbackTail: String

        public init(
            live: Bool, dead: Bool, cols: Int, rows: Int, proc: String?, selection: String?, scrollbackTail: String
        ) {
            self.live = live
            self.dead = dead
            self.cols = cols
            self.rows = rows
            self.proc = proc
            self.selection = selection
            self.scrollbackTail = scrollbackTail
        }
    }

    public struct Card: Equatable, Sendable {
        public enum Content: Equatable, Sendable {
            case doc
            case term(Terminal)
        }

        public var id: String
        public var content: Content
        /// The card's world frame.
        public var frame: CGRect
        /// Where the card's view is on screen, as measured; nil when it has none.
        public var screenRect: CGRect?

        public init(id: String, content: Content, frame: CGRect, screenRect: CGRect?) {
            self.id = id
            self.content = content
            self.frame = frame
            self.screenRect = screenRect
        }

        public var kind: DevCardKind {
            switch content {
            case .doc: .doc
            case .term: .term
            }
        }
    }

    /// Which card holds keyboard focus — a different fact from the selected card;
    /// the two disagree legitimately, which is why both are reported.
    public enum KeyboardFocus: Equatable, Sendable {
        case terminal(card: String, hasSelection: Bool)
        /// A borrowed HTML card whose document is first responder.
        case htmlDocument(card: String)
        /// The board, a markdown card, or anything that is not one of the above.
        case none

        /// The card `type` and `key` require focus to already be on.
        public var card: String? {
            switch self {
            case .terminal(let card, _), .htmlDocument(let card): card
            case .none: nil
            }
        }
    }

    public enum SelectionType: String, Equatable, Sendable {
        case none = "None"
        case caret = "Caret"
        case range = "Range"
    }

    /// Keyboard focus in the vocabulary the scenario suite reads. That vocabulary
    /// is the Tauri app's DOM — `document.activeElement`'s tag and classes, and
    /// the page selection's type — so native focus is mapped onto the element the
    /// same state had there, keeping one suite for both apps:
    ///
    ///     terminal        TEXTAREA  xterm-helper-textarea  Caret, or Range with a selection
    ///     HTML document   IFRAME    html-frame             None
    ///     otherwise       BODY      (no classes)           None
    public struct ActiveElement: Equatable, Sendable {
        public var card: String?
        public var tag: String
        public var classes: [String]
        public var selectionType: SelectionType

        public init(_ focus: KeyboardFocus) {
            card = focus.card
            switch focus {
            case .terminal(_, let hasSelection):
                tag = "TEXTAREA"
                classes = ["xterm-helper-textarea"]
                selectionType = hasSelection ? .range : .caret
            case .htmlDocument:
                tag = "IFRAME"
                classes = ["html-frame"]
                selectionType = .none
            case .none:
                tag = "BODY"
                classes = []
                selectionType = .none
            }
        }

        var json: JSONValue {
            [
                "card": optional(card),
                "tag": .string(tag),
                "classes": .array(classes.map(JSONValue.string)),
                "selection_type": .string(selectionType.rawValue),
            ]
        }
    }

    /// The hold-⌘Q guard's own facts (#171, #183).
    public struct QuitGuard: Equatable, Sendable {
        public enum Phase: String, Equatable, Sendable {
            case idle, showing, confirming
        }

        public enum Route: String, Equatable, Sendable {
            case `guard`, terminate
        }

        public struct Press: Equatable, Sendable {
            public var pressMs: UInt64
            public var route: Route
            public var ageMs: Int64

            public init(pressMs: UInt64, route: Route, ageMs: Int64) {
                self.pressMs = pressMs
                self.route = route
                self.ageMs = ageMs
            }
        }

        public var retargeted: Bool
        public var enabled: Bool
        public var phase: Phase
        public var noticeVisible: Bool
        public var noticeAlpha: Double
        public var lastPress: Press?

        public init(
            retargeted: Bool, enabled: Bool, phase: Phase, noticeVisible: Bool, noticeAlpha: Double, lastPress: Press?
        ) {
            self.retargeted = retargeted
            self.enabled = enabled
            self.phase = phase
            self.noticeVisible = noticeVisible
            self.noticeAlpha = noticeAlpha
            self.lastPress = lastPress
        }
    }

    public struct Input: Equatable, Sendable {
        public var boardID: String
        public var visibility: Visibility
        public var viewport: Viewport
        /// The board view's own rect — what turns board-local into window points.
        public var viewRect: CGRect
        /// The ACTIVE board's cards, in the order they should be reported.
        public var cards: [Card]
        public var selectedCard: String?
        /// The HTML card whose document takes input, if any.
        public var borrowedCard: String?
        public var keyboardFocus: KeyboardFocus
        /// Nil when the guard could not be read.
        public var quitGuard: QuitGuard?

        public init(
            boardID: String,
            visibility: Visibility,
            viewport: Viewport,
            viewRect: CGRect,
            cards: [Card],
            selectedCard: String?,
            borrowedCard: String?,
            keyboardFocus: KeyboardFocus,
            quitGuard: QuitGuard?
        ) {
            self.boardID = boardID
            self.visibility = visibility
            self.viewport = viewport
            self.viewRect = viewRect
            self.cards = cards
            self.selectedCard = selectedCard
            self.borrowedCard = borrowedCard
            self.keyboardFocus = keyboardFocus
            self.quitGuard = quitGuard
        }
    }

    public static func build(_ input: Input) -> JSONValue {
        [
            "v": 1,
            "board_id": .string(input.boardID),
            "visibility": .string(input.visibility.rawValue),
            "viewport": [
                "zoom": .number(input.viewport.zoom),
                "cx": .number(input.viewport.center.x),
                "cy": .number(input.viewport.center.y),
                "view_rect": rect(input.viewRect),
            ],
            "cards": .array(input.cards.map { card(for: $0, in: input) }),
            "focused_card": optional(input.selectedCard),
            "active_element": ActiveElement(input.keyboardFocus).json,
            "quit_guard": input.quitGuard.map(quitGuard) ?? .null,
        ]
    }

    /// `focus`'s reply: the two facts a focus changes, read after the UI settled.
    public static func focusReply(selectedCard: String?, keyboardFocus: KeyboardFocus) -> JSONValue {
        ["focused_card": optional(selectedCard), "active_element": ActiveElement(keyboardFocus).json]
    }

    /// `zoom`'s reply: the zoom the board ended at, which the clamp may have
    /// moved off the one requested.
    public static func zoomReply(observed zoom: CGFloat) -> JSONValue {
        ["zoom": .number(zoom)]
    }

    /// World units → window points. Never used for `screen_rect` itself; it is
    /// the transform a measured rect is compared against.
    public static func screenRect(of boardRect: CGRect, viewport: Viewport, viewRect: CGRect) -> CGRect {
        let viewportCenter = CGPoint(x: viewRect.midX, y: viewRect.midY)
        let topLeft = BoardTransform.worldToView(
            boardRect.origin, zoom: viewport.zoom, center: viewport.center, viewportCenter: viewportCenter
        )
        let bottomRight = BoardTransform.worldToView(
            CGPoint(x: boardRect.maxX, y: boardRect.maxY),
            zoom: viewport.zoom, center: viewport.center, viewportCenter: viewportCenter
        )
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    private static func card(for card: Card, in input: Input) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(card.id),
            "kind": .string(card.kind.rawValue),
            "board_rect": rect(card.frame),
            "screen_rect": card.screenRect.map(rect) ?? .null,
            "focused": .bool(card.id == input.selectedCard),
        ]
        switch card.content {
        case .doc:
            fields["borrowed"] = .bool(card.id == input.borrowedCard)
        case .term(let terminal):
            fields["term"] = [
                "alive": .bool(terminal.live && !terminal.dead),
                "cols": .number(Double(terminal.cols)),
                "rows": .number(Double(terminal.rows)),
                "proc": optional(terminal.proc),
                // "" would make `contains ""` match vacuously.
                "selection": optional(terminal.selection.flatMap { $0.isEmpty ? nil : $0 }),
                "scrollback_tail": .string(terminal.scrollbackTail),
            ]
        }
        return .object(fields)
    }

    private static func quitGuard(_ facts: QuitGuard) -> JSONValue {
        [
            "retargeted": .bool(facts.retargeted),
            "enabled": .bool(facts.enabled),
            "phase": .string(facts.phase.rawValue),
            "notice": [
                "visible": .bool(facts.noticeVisible),
                // A hidden panel keeps the alpha it was left at, which AppKit
                // resets to 1; reported, that reads as a notice at full opacity.
                "alpha": .number(facts.noticeVisible ? facts.noticeAlpha : 0),
            ],
            "last_press": facts.lastPress.map { press in
                [
                    "press_ms": .number(Double(press.pressMs)),
                    "route": .string(press.route.rawValue),
                    "age_ms": .number(Double(press.ageMs)),
                ]
            } ?? .null,
        ]
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        [
            "x": .number(rect.origin.x),
            "y": .number(rect.origin.y),
            "w": .number(rect.size.width),
            "h": .number(rect.size.height),
        ]
    }

    private static func optional(_ text: String?) -> JSONValue {
        text.map(JSONValue.string) ?? .null
    }
}
