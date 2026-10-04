import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Presses and selection

    /// The deepest view under a window-space point, or nil.
    private func hitView(at point: NSPoint) -> NSView? {
        window?.contentView?.hitTest(point)
    }

    /// The card a hit view belongs to — its header, body or a resize handle —
    /// or nil for the bare board and the overlays.
    private func enclosingCard(_ view: NSView?) -> CardView? {
        view?.enclosing(CardView.self)
    }

    /// A left-button press, seen before the view under it handles it.
    func handlePress(at point: NSPoint) {
        handlePress(on: hitView(at: point))
    }

    /// A left-button press that lands on `hit`. On a card it selects and raises
    /// that card, and a live terminal also becomes prime; on the bare board it
    /// clears the selection. A press on an overlay, or on a header control or a
    /// doc's link, which act by themselves, changes nothing here (`CardPress`).
    func handlePress(on hit: NSView?) {
        guard !switcherOpen, window?.isKeyWindow == true else { return }
        guard let hit, hit.isDescendant(of: rootView.board) else { return }
        guard let card = enclosingCard(hit) else { return defocus() }
        guard CardPress.selects(card.pressPlace(of: hit)) else { return }
        select(card.id)
    }

    private func select(_ id: CardID) {
        let board = activeBoard.view
        guard board.card(id) != nil else { return }
        board.select(id)
        board.raise(id)
        if case let .term(termID) = id, sessions[termID]?.live == true {
            setPrime(termID)
            clearBell(termID: termID)
        }
    }

    /// Clears the selection, so the wheel pans the board wherever the pointer
    /// is. The prime terminal is untouched.
    func defocus() {
        activeBoard.view.select(nil)
    }

    /// Takes the fresh mark off every doc card on the active board, leaving the
    /// cards where they are. False when no card had it.
    func clearFreshDocs() -> Bool {
        let cards = Array(activeBoard.view.cards.values)
        guard cards.contains(where: \.isFreshDoc) else { return false }
        _ = ClearFreshDoc.apply(to: cards)
        return true
    }

    // MARK: - Wheel and pinch

    /// A wheel event, seen before it is dispatched. Over the body of the
    /// selected card it is left for that card's own content; anywhere else on
    /// the board it pans, and with control held it zooms about the pointer.
    /// True means the board took it. Overlays and the switcher keep their own
    /// wheel.
    func routeScroll(_ event: NSEvent) -> Bool {
        guard !switcherOpen else { return false }
        let board = rootView.board
        guard let hit = hitView(at: event.locationInWindow), hit.isDescendant(of: board) else { return false }
        let card = enclosingCard(hit)
        let route = BoardWheel.route(
            pinch: event.modifierFlags.contains(.control),
            over: card?.id,
            inBody: card?.bodyContains(hit) ?? false,
            selected: focusedCardID
        )
        let travel = BoardWheel.travel(
            scrollingDelta: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas
        )
        switch route {
        case .card:
            card?.tookWheel()
            return false
        case .pan:
            board.pan(by: travel)
        case .zoom:
            board.zoom(
                by: BoardWheel.zoomFactor(travel: travel),
                anchorViewPoint: board.convert(event.locationInWindow, from: nil)
            )
        }
        return true
    }

    /// A pinch over the board always zooms the board, even over the selected card.
    func routeMagnify(_ event: NSEvent) -> Bool {
        guard !switcherOpen else { return false }
        guard let hit = hitView(at: event.locationInWindow), hit.isDescendant(of: rootView.board) else { return false }
        rootView.board.magnify(with: event)
        return true
    }

    // MARK: - Prime terminal

    /// Restyles a board's cards for its prime terminal: that card is prime and
    /// the other live terminals are quiet. Nothing is prime, and nothing quiet,
    /// while no terminal on the board is live.
    func updatePrimacy(on board: Board? = nil) {
        let b = board ?? activeBoard
        let primeID: CardID? = b.hasLivePrime ? b.primeTermID.map(CardID.term) : nil
        for (id, card) in b.view.cards {
            let isPrime = id == primeID
            let isTerminal: Bool
            if case .term = id { isTerminal = true } else { isTerminal = false }
            card.setPrime(isPrime)
            card.setQuiet(CardDim.isQuiet(
                terminal: isTerminal, prime: isPrime, dead: card.dead, boardHasPrime: primeID != nil
            ))
        }
    }

    /// Makes `termID` the prime terminal: restyles the board for it and gives
    /// its view keyboard focus.
    func setPrime(_ termID: String) {
        guard let s = sessions[termID] else { return }
        primeTermID = termID
        updatePrimacy()
        window?.makeFirstResponder(s.view)
    }
}
