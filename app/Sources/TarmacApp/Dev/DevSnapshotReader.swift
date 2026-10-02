#if DEBUG
import AppKit
import TarmacKit
import TarmacTerm

/// Reads the facts `tarmac dev snapshot` reports off the live views. Every
/// decision about them is `DevSnapshot`'s; this only measures.
@MainActor
struct DevSnapshotReader {
    let controller: AppController
    let quitGuard: QuitGuardController?

    private var board: BoardView { controller.activeBoard.view }

    /// The active board's cards, in the order they are reported.
    var cards: [CardView] {
        DevSnapshot.cardOrder(
            terminals: controller.sessionOrder,
            listedDocs: controller.store.docs.map(\.path),
            onBoard: Set(board.cards.keys.map(\.wireRef))
        ).compactMap { board.card(CardID($0)) }
    }

    func snapshot() -> JSONValue {
        DevSnapshot.build(DevSnapshot.Input(
            boardID: controller.activeBoardID,
            visibility: DevSnapshot.Visibility(
                windowVisible: controller.window?.isVisible ?? false,
                miniaturized: controller.window?.isMiniaturized ?? false
            ),
            viewport: DevSnapshot.Viewport(
                zoom: board.viewport.zoom, center: CGPoint(x: board.viewport.cx, y: board.viewport.cy)
            ),
            viewRect: controller.rootView.convert(board.bounds, from: board),
            cards: cards.map(fact),
            selectedCard: board.selectedID?.wireID,
            borrowedCard: controller.borrow.id?.wireID,
            keyboardFocus: keyboardFocus,
            quitGuard: quitGuard?.facts
        ))
    }

    var routingContext: DevRouting.Context {
        DevRouting.Context(
            cards: cards.map { card in
                DevRouting.Card(id: card.id.wireID, kind: card.id.wireRef.kind, frame: card.worldFrame.rect)
            },
            keyboardFocusCard: keyboardFocus.card,
            borrowedCard: controller.borrow.id?.wireID,
            zoom: board.viewport.zoom,
            center: CGPoint(x: board.viewport.cx, y: board.viewport.cy),
            viewSize: board.bounds.size
        )
    }

    /// Keyboard focus is the first responder's whether or not the window is
    /// key, as `activeElement` is the document's.
    var keyboardFocus: DevSnapshot.KeyboardFocus {
        let switcher = controller.rootView.boardSwitcher
        let responder = controller.window?.firstResponder
        return DevSnapshot.KeyboardFocus(
            responder: holder(of: responder),
            switcherOwner: holder(of: switcher.keysOwner),
            switcherHoldsKeys: responder === switcher
        )
    }

    /// The card whose view is, or contains, `responder`.
    private func holder(of responder: NSResponder?) -> DevSnapshot.KeyHolder? {
        guard let view = responder as? NSView else { return nil }
        for (termID, session) in controller.sessions where view.isDescendant(of: session.view) {
            return .terminal(card: termID, hasSelection: session.view.hasSelection)
        }
        for card in board.cards.values {
            guard case .doc(let path) = card.id else { continue }
            // An HTML card's console can hold a selection, and so the keys,
            // without its document having them.
            let holds = card.htmlBody.map { $0.documentHoldsKeys(view) } ?? view.isDescendant(of: card)
            if holds { return .doc(path: path) }
        }
        return nil
    }

    private func fact(_ card: CardView) -> DevSnapshot.Card {
        DevSnapshot.Card(
            id: card.id.wireID,
            content: content(of: card),
            frame: card.worldFrame.rect,
            screenRect: card.superview.map { controller.rootView.convert(card.frame, from: $0) }
        )
    }

    private func content(of card: CardView) -> DevSnapshot.Card.Content {
        guard case .term(let termID) = card.id else { return .doc }
        let session = controller.sessions[termID]
        let view = session?.view
        return .term(DevSnapshot.Terminal(
            live: session?.live ?? false,
            dead: card.dead,
            cols: view?.cols ?? 0,
            rows: view?.rows ?? 0,
            proc: session?.procName,
            selection: view?.selectedText,
            scrollbackTail: view?.engine.tail(lines: DevSnapshot.scrollbackTailLines) ?? ""
        ))
    }
}

extension CardID {
    init(_ ref: DevSnapshot.CardRef) {
        switch ref.kind {
        case .term: self = .term(ref.id)
        case .doc: self = .doc(ref.id)
        }
    }

    /// The card as the driver's callers address it.
    var wireRef: DevSnapshot.CardRef {
        switch self {
        case .term(let termID): DevSnapshot.CardRef(kind: .term, id: termID)
        case .doc(let path): DevSnapshot.CardRef(kind: .doc, id: path)
        }
    }

    var wireID: String { wireRef.id }
}
#endif
