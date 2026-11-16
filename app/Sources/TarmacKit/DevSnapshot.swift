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

        /// Hidden is a window nobody can see: ordered out or miniaturized. One
        /// merely behind another app's window still draws, and is visible.
        public init(windowVisible: Bool, miniaturized: Bool) {
            self = windowVisible && !miniaturized ? .visible : .hidden
        }
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
        /// #380: the cursor's row from the top of the scrollback.
        public var cursorRow: Int
        /// 2611.0011: the resume offer the card shows, if any.
        public var resume: Resume?
        /// The dead card offers to reopen.
        public var reopen: Bool
        /// 2611.0015: the command the header chip copies, while it shows.
        public var resumeChip: String?

        public init(
            live: Bool, dead: Bool, cols: Int, rows: Int, proc: String?, selection: String?, scrollbackTail: String,
            cursorRow: Int = 0, resume: Resume? = nil, reopen: Bool = false, resumeChip: String? = nil
        ) {
            self.cursorRow = cursorRow
            self.resumeChip = resumeChip
            self.live = live
            self.dead = dead
            self.cols = cols
            self.rows = rows
            self.proc = proc
            self.selection = selection
            self.scrollbackTail = scrollbackTail
            self.resume = resume
            self.reopen = reopen
        }
    }

    /// An offer as its card shows it: the panel's own model, so a runner
    /// checks the copy the user reads.
    public struct Resume: Equatable, Sendable {
        public var offer: ResumeOffer
        public var prime: Bool

        public init(offer: ResumeOffer, prime: Bool) {
            self.offer = offer
            self.prime = prime
        }

        public var armed: Bool { offer.armed(prime: prime) }
        public var queued: Bool { offer.queued }
        public var panel: ResumePanel.Model { ResumePanel.model(offer: offer, prime: prime) }
    }

    /// A card's scroll position and the two facts its thumb's showing rests on.
    public struct Scroll: Equatable, Sendable {
        public var metrics: ScrollMetrics
        /// The card has a thumb frame and is not culled.
        public var laidOut: Bool
        /// The thumb's `Visibility` alpha at the time of the snapshot.
        public var alpha: CGFloat
        /// The thumb view's frame, in the coordinates of the card's
        /// `screenRect`; nil when it has none.
        public var thumb: CGRect?

        public init(metrics: ScrollMetrics, laidOut: Bool, alpha: CGFloat, thumb: CGRect?) {
            self.metrics = metrics
            self.laidOut = laidOut
            self.alpha = alpha
            self.thumb = thumb
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
        /// Nil until the card's content has reported.
        public var scroll: Scroll?

        public init(id: String, content: Content, frame: CGRect, screenRect: CGRect?, scroll: Scroll?) {
            self.id = id
            self.content = content
            self.frame = frame
            self.screenRect = screenRect
            self.scroll = scroll
        }

        public var kind: DevCardKind {
            switch content {
            case .doc: .doc
            case .term: .term
            }
        }
    }

    /// The overlays that hold first responder while they are up.
    public enum Overlay: String, Equatable, Sendable {
        case switcher, restoreCard = "restore_card", inbox
    }

    /// Who holds keyboard focus — a different fact from the selected card;
    /// the two disagree legitimately, which is why both are reported.
    public indirect enum KeyboardFocus: Equatable, Sendable {
        case terminal(card: String, hasSelection: Bool)
        /// A borrowed HTML card whose document is first responder.
        case htmlDocument(card: String)
        /// An overlay holds first responder (#364): the keys reach no card.
        /// `returnsTo` is where it hands them back when it closes.
        case overlay(Overlay, returnsTo: KeyboardFocus)
        /// The board, a markdown card, or anything that is not one of the above.
        case none

        /// The card `type` and `key` require focus to already be on.
        public var card: String? {
            switch self {
            case .terminal(let card, _), .htmlDocument(let card): card
            case .overlay, .none: nil
            }
        }

        /// Maps the window's first responder onto who holds the keys. While
        /// `overlay` is up, `overlayOwner` is the card it took them from.
        public init(responder: KeyHolder?, overlay: Overlay?, overlayOwner: KeyHolder?) {
            if let overlay {
                self = .overlay(overlay, returnsTo: KeyboardFocus(responder: overlayOwner, overlay: nil, overlayOwner: nil))
                return
            }
            switch responder {
            case .terminal(let card, let hasSelection):
                self = .terminal(card: card, hasSelection: hasSelection)
            case .doc(let path) where DocKind(path: path) == .html:
                self = .htmlDocument(card: path)
            case .doc, nil:
                self = .none
            }
        }
    }

    /// The card whose view is, or contains, a responder.
    public enum KeyHolder: Equatable, Sendable {
        case terminal(card: String, hasSelection: Bool)
        case doc(path: String)
    }

    /// A card by its wire id. The kind is part of it: a term id and a doc path
    /// are different namespaces.
    public struct CardRef: Hashable, Sendable {
        public var kind: DevCardKind
        public var id: String

        public init(kind: DevCardKind, id: String) {
            self.kind = kind
            self.id = id
        }
    }

    /// The order cards are reported in: terminals in the board's card order,
    /// then docs in the order the board lists them. Both orders may name cards
    /// that are not on the board; only `onBoard` is reported. A card neither
    /// names comes last — terminals before docs, by id — so that two snapshots
    /// of one board agree.
    public static func cardOrder(terminals: [String], listedDocs: [String], onBoard: Set<CardRef>) -> [CardRef] {
        let named = (terminals.map { CardRef(kind: .term, id: $0) } + listedDocs.map { CardRef(kind: .doc, id: $0) })
            .filter(onBoard.contains)
        let unnamed = onBoard.subtracting(named).sorted { a, b in
            a.kind == b.kind ? a.id < b.id : a.kind == .term
        }
        return named + unnamed
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
    ///     an overlay      DIALOG    tm-overlay <name>      None
    ///     otherwise       BODY      (no classes)           None
    ///
    /// `card` is the card the keys reach now. Only while an overlay holds them
    /// are two more keys present: `overlay`, its name, and `returns_to`, the
    /// card it hands them back to on close, or null.
    public struct ActiveElement: Equatable, Sendable {
        public var card: String?
        public var tag: String
        public var classes: [String]
        public var selectionType: SelectionType
        public var overlay: Overlay?
        public var returnsTo: String?

        public init(_ focus: KeyboardFocus) {
            card = focus.card
            overlay = nil
            returnsTo = nil
            switch focus {
            case .overlay(let name, let owner):
                tag = "DIALOG"
                classes = ["tm-overlay", name.rawValue]
                selectionType = .none
                overlay = name
                returnsTo = owner.card
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
            var fields: [String: JSONValue] = [
                "card": optional(card),
                "tag": .string(tag),
                "classes": .array(classes.map(JSONValue.string)),
                "selection_type": .string(selectionType.rawValue),
            ]
            if let overlay {
                fields["overlay"] = .string(overlay.rawValue)
                fields["returns_to"] = optional(returnsTo)
            }
            return .object(fields)
        }
    }

    /// The hold-⌘Q guard's own facts (#171, #183).
    public struct QuitGuard: Equatable, Sendable {
        public enum Phase: String, Equatable, Sendable {
            case idle, showing, confirming

            public init(_ phase: TarmacKit.QuitGuard.Phase) {
                switch phase {
                case .idle: self = .idle
                case .showing: self = .showing
                case .confirming: self = .confirming
                }
            }
        }

        public enum Route: String, Equatable, Sendable {
            case `guard`, terminate

            public init(_ route: TarmacKit.QuitGuard.Route) {
                switch route {
                case .guarded: self = .guard
                case .terminateNow: self = .terminate
                }
            }
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

    /// The chosen fonts (specs 2610.0005, 2610.0006): what is saved for each
    /// role, what each role resolved to on this Mac, and the size in effect
    /// of the two roles that have one.
    public struct Fonts: Equatable, Sendable {
        public var saved: [FontRole: String]
        /// The PostScript name of the regular face terminals are set in.
        public var terminalFace: String
        public var terminalSize: Double
        /// The PostScript name of the regular face the chrome is set in.
        public var interfaceFace: String
        /// The `font-family` value doc-card prose is given.
        public var documentCSS: String
        public var documentSize: Double

        public init(
            saved: [FontRole: String], terminalFace: String, terminalSize: Double, interfaceFace: String,
            documentCSS: String, documentSize: Double
        ) {
            self.saved = saved
            self.terminalFace = terminalFace
            self.terminalSize = terminalSize
            self.interfaceFace = interfaceFace
            self.documentCSS = documentCSS
            self.documentSize = documentSize
        }
    }

    /// The theme (specs 2610.0007, 2610.0008, 2610.0009): the choice the app
    /// holds, the variant and the id of the theme whose palette it holds, and
    /// what the user's theme files gave.
    public struct Theme: Equatable, Sendable {
        public var choice: ThemeChoice
        public var inEffect: ThemeVariant
        public var name: String
        /// Where the theme files are read from.
        public var folder: String
        /// The id of every theme, in the order of the list.
        public var available: [String]
        /// Each file that is no theme, with the reason.
        public var refused: [String]
        /// What the detector found in the theme in effect.
        public var findings: [String]

        public init(
            choice: ThemeChoice, inEffect: ThemeVariant, name: String, folder: String = "",
            available: [String] = [], refused: [String] = [], findings: [String] = []
        ) {
            self.choice = choice
            self.inEffect = inEffect
            self.name = name
            self.folder = folder
            self.available = available
            self.refused = refused
            self.findings = findings
        }
    }

    /// The inbox panel (2611.0013): its state and the items of its filter.
    public struct InboxFacts: Equatable, Sendable {
        public var open: Bool
        public var unread: Int
        public var filter: Inbox.Filter
        public var selected: Inbox.ItemID?
        /// In list order.
        public var items: [Inbox.Item]

        public init(
            open: Bool = false, unread: Int = 0, filter: Inbox.Filter = .all, selected: Inbox.ItemID? = nil,
            items: [Inbox.Item] = []
        ) {
            self.open = open
            self.unread = unread
            self.filter = filter
            self.selected = selected
            self.items = items
        }
    }

    /// One offscreen pill as placed.
    public struct Hint: Equatable, Sendable {
        public var card: String
        public var signal: OffscreenHintLayout.Signal
        public var edge: BoardWayfinding.Edge

        public init(card: String, signal: OffscreenHintLayout.Signal, edge: BoardWayfinding.Edge) {
            self.card = card
            self.signal = signal
            self.edge = edge
        }
    }

    public struct Input: Equatable, Sendable {
        public var boardID: String
        public var visibility: Visibility
        public var viewport: Viewport
        /// The board view's own rect — what turns board-local into window points.
        public var viewRect: CGRect
        /// Where the origin of the window's content coordinates lies on the
        /// display, in global top-left points; nil when there is no window.
        public var contentOrigin: CGPoint?
        /// The ACTIVE board's cards, in the order they should be reported.
        public var cards: [Card]
        public var selectedCard: String?
        /// The HTML card whose document takes input, if any.
        public var borrowedCard: String?
        public var keyboardFocus: KeyboardFocus
        /// Nil when the guard could not be read.
        public var quitGuard: QuitGuard?
        public var fonts: Fonts
        public var theme: Theme
        /// #358: the restore card while it is up.
        public var restoreCard: RestoreCard?
        public var inbox: InboxFacts
        public var hints: [Hint]
        /// 2611.0015: the titles of the toasts on screen, oldest first.
        public var toasts: [String]

        public init(
            boardID: String,
            visibility: Visibility,
            viewport: Viewport,
            viewRect: CGRect,
            contentOrigin: CGPoint?,
            cards: [Card],
            selectedCard: String?,
            borrowedCard: String?,
            keyboardFocus: KeyboardFocus,
            quitGuard: QuitGuard?,
            fonts: Fonts,
            theme: Theme,
            restoreCard: RestoreCard? = nil,
            inbox: InboxFacts = InboxFacts(),
            hints: [Hint] = [],
            toasts: [String] = []
        ) {
            self.toasts = toasts
            self.boardID = boardID
            self.visibility = visibility
            self.viewport = viewport
            self.viewRect = viewRect
            self.contentOrigin = contentOrigin
            self.cards = cards
            self.selectedCard = selectedCard
            self.borrowedCard = borrowedCard
            self.keyboardFocus = keyboardFocus
            self.quitGuard = quitGuard
            self.fonts = fonts
            self.theme = theme
            self.restoreCard = restoreCard
            self.inbox = inbox
            self.hints = hints
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
            "content_origin": input.contentOrigin.map { ["x": .number($0.x), "y": .number($0.y)] } ?? .null,
            "focused_card": optional(input.selectedCard),
            "active_element": ActiveElement(input.keyboardFocus).json,
            "quit_guard": input.quitGuard.map(quitGuard) ?? .null,
            "fonts": fonts(input.fonts),
            "theme": theme(input.theme),
            "restore_card": input.restoreCard.map { card in
                [
                    "lines": .array(card.lines.map { .string($0.string) }),
                    "choices": .array(card.choices.map { .string($0.text) }),
                ]
            } ?? .null,
            "inbox": inbox(input.inbox),
            "toasts": .array(input.toasts.map(JSONValue.string)),
            "hints": .array(input.hints.map { hint in
                [
                    "card": .string(hint.card), "signal": .string(signalName(hint.signal)),
                    "edge": .string(hint.edge.rawValue),
                ]
            }),
        ]
    }

    private static func inbox(_ facts: InboxFacts) -> JSONValue {
        let selected = facts.selected.flatMap { id in facts.items.first { $0.id == id } }
        return [
            "open": .bool(facts.open),
            "badge": .string(InboxBadge.text(unread: facts.unread)),
            "filter": .string(facts.filter.rawValue),
            "selected": selected.map { ["kind": .string(InboxCopy.tag($0.kind)), "term": .string($0.termID)] } ?? .null,
            "items": .array(facts.items.map { item in
                [
                    "kind": .string(InboxCopy.tag(item.kind)), "term": .string(item.termID),
                    "board": .string(item.boardID), "read": .bool(item.read), "title": .string(InboxCopy.title(item)),
                ]
            }),
        ]
    }

    private static func signalName(_ signal: OffscreenHintLayout.Signal) -> String {
        switch signal {
        case .blocked: "blocked"
        case .bell: "bell"
        case .exit: "exit"
        case .done: "done"
        case .live: "live"
        }
    }

    private static func theme(_ theme: Theme) -> JSONValue {
        [
            "choice": .string(theme.choice.rawValue), "in_effect": .string(theme.inEffect.rawValue),
            "name": .string(theme.name), "folder": .string(theme.folder),
            "available": .array(theme.available.map(JSONValue.string)),
            "refused": .array(theme.refused.map(JSONValue.string)),
            "findings": .array(theme.findings.map(JSONValue.string)),
        ]
    }

    private static func fonts(_ fonts: Fonts) -> JSONValue {
        [
            "terminal": [
                "saved": optional(fonts.saved[.terminal]), "face": .string(fonts.terminalFace),
                "size": .number(fonts.terminalSize),
            ],
            "interface": ["saved": optional(fonts.saved[.interface]), "face": .string(fonts.interfaceFace)],
            "document": [
                "saved": optional(fonts.saved[.document]), "css": .string(fonts.documentCSS),
                "size": .number(fonts.documentSize),
            ],
        ]
    }

    /// A Cocoa screen point (bottom-left origin) as a global display point
    /// (top-left origin), given the primary screen's height.
    public static func displayPoint(cocoa: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: cocoa.x, y: primaryScreenHeight - cocoa.y)
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
            "scroll": card.scroll.map(scroll) ?? .null,
        ]
        switch card.content {
        case .doc:
            fields["borrowed"] = .bool(card.id == input.borrowedCard)
        case .term(let terminal):
            var term: [String: JSONValue] = [
                "alive": .bool(terminal.live && !terminal.dead),
                "cols": .number(Double(terminal.cols)),
                "rows": .number(Double(terminal.rows)),
                "proc": optional(terminal.proc),
                // "" would make `contains ""` match vacuously.
                "selection": optional(terminal.selection.flatMap { $0.isEmpty ? nil : $0 }),
                "scrollback_tail": .string(terminal.scrollbackTail),
                "cursor_row": .number(Double(terminal.cursorRow)),
            ]
            // Present only with an offer (2611.0011) or a chip (2611.0015): a
            // terminal with none keeps its seven keys.
            if let resume = terminal.resume {
                let panel = resume.panel
                term["resume"] = [
                    "cmd": .string(panel.command), "armed": .bool(resume.armed), "queued": .bool(resume.queued),
                    "title": .string(panel.title), "buttons": .array(panel.buttons.map { .string($0.text) }),
                ]
            }
            if terminal.reopen { term["reopen"] = true }
            if let chip = terminal.resumeChip { term["resume_chip"] = .string(chip) }
            fields["term"] = .object(term)
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

    private static func scroll(_ scroll: Scroll) -> JSONValue {
        [
            "offset": .number(scroll.metrics.offset),
            "visible": .number(scroll.metrics.visible),
            "total": .number(scroll.metrics.total),
            "shown": .bool(scroll.laidOut && scroll.alpha > 0),
            "thumb": scroll.laidOut ? scroll.thumb.map(rect) ?? .null : .null,
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
