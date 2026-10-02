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

    /// The active board's cards: terminals in card order, then docs in the
    /// order the board lists them.
    var cards: [CardView] {
        let terms = controller.sessionOrder.compactMap { board.card(.term($0)) }
        let listed = controller.store.docs.compactMap { board.card(.doc($0.path)) }
        let unlisted = board.cards.values
            .filter { card in card.id.wireKind == .doc && !listed.contains { $0 === card } }
            .sorted { $0.id.wireID < $1.id.wireID }
        return terms + listed + unlisted
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
                DevRouting.Card(id: card.id.wireID, kind: card.id.wireKind, frame: card.worldFrame.rect)
            },
            keyboardFocusCard: keyboardFocus.card,
            borrowedCard: controller.borrow.id?.wireID,
            zoom: board.viewport.zoom,
            center: CGPoint(x: board.viewport.cx, y: board.viewport.cy),
            viewSize: board.bounds.size
        )
    }

    /// The card whose view holds the window's first responder, whether or not
    /// the window is key: keyboard focus is the view's, as `activeElement` is
    /// the document's.
    var keyboardFocus: DevSnapshot.KeyboardFocus {
        guard let responder = controller.window?.firstResponder as? NSView else { return .none }
        for (termID, session) in controller.sessions where responder.isDescendant(of: session.view) {
            return .terminal(card: termID, hasSelection: session.view.hasSelection)
        }
        for card in board.cards.values {
            guard case .doc(let path) = card.id, DocKind(path: path) == .html, responder.isDescendant(of: card)
            else { continue }
            return .htmlDocument(card: path)
        }
        return .none
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
    /// The bare id the driver's callers address a card by.
    var wireID: String {
        switch self {
        case .term(let termID): termID
        case .doc(let path): path
        }
    }

    var wireKind: DevCardKind {
        switch self {
        case .term: .term
        case .doc: .doc
        }
    }
}
#endif
