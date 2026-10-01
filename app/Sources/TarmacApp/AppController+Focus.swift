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
        var v = view
        while let cur = v {
            if let card = cur as? CardView { return card }
            v = cur.superview
        }
        return nil
    }

    /// A left-button press, seen before the view under it handles it. On a card
    /// it selects and raises that card, and a live terminal also becomes prime;
    /// on the bare board it clears the selection. A press on an overlay, or on a
    /// header control that acts by itself, changes nothing here.
    func handlePress(at point: NSPoint) {
        guard !switcherOpen, window?.isKeyWindow == true else { return }
        guard let hit = hitView(at: point), hit.isDescendant(of: rootView.board) else { return }
        guard let card = enclosingCard(hit) else { return defocus() }
        if hit is HeaderButton { return }
        select(card.id)
    }

    private func select(_ id: CardID) {
        let board = activeBoard.view
        guard board.card(id) != nil else { return }
        board.select(id)
        board.raise(id)
        if case let .term(termID) = id, sessions[termID]?.live == true { setPrime(termID) }
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

    /// Point 2: a scroll/pan routes to the whiteboard — pans the board and returns
    /// `true` to swallow the event — UNLESS the pointer is inside the focused card,
    /// in which case it returns `false` so the event passes through to that card's
    /// own content (terminal scrollback / doc scroll). Events over the overlays or
    /// outside the board return `false` (left untouched).
    func routeScroll(_ event: NSEvent) -> Bool {
        guard !switcherOpen else { return false }
        guard let hit = hitView(at: event.locationInWindow), hit.isDescendant(of: rootView.board) else { return false }
        if let fid = focusedCardID, activeBoard.view.card(fid) != nil,
           enclosingCard(hit)?.id == fid {
            return false
        }
        rootView.board.scrollWheel(with: event)
        return true
    }

    /// Point 2: pinch always zooms the whiteboard (anchored at the pointer) and
    /// swallows the event, even over a focused terminal — a terminal has no pinch
    /// behavior of its own. Over an overlay / outside the board it passes through.
    func routeMagnify(_ event: NSEvent) -> Bool {
        guard !switcherOpen else { return false }
        guard let hit = hitView(at: event.locationInWindow), hit.isDescendant(of: rootView.board) else { return false }
        rootView.board.magnify(with: event)
        return true
    }

    /// Reconciles `primeTermID` to whichever LIVE terminal currently holds the
    /// window's keyboard focus — e.g. the user clicked a non-prime terminal,
    /// which AppKit made first responder (typing already routes there via its
    /// `onInput`). Called before any action that re-asserts focus to the prime
    /// terminal (cycle / board switch), so focus is never yanked back to a stale
    /// prime. No-op when the focused responder isn't a live terminal view.
    func reconcilePrimeToFocus() {
        guard let s = focusedLiveSession(), s.termID != primeTermID else { return }
        primeTermID = s.termID
        updatePrimacy()
    }

    /// The live terminal session on the active board whose view currently holds
    /// keyboard focus (the first responder, or an ancestor of it), or nil.
    private func focusedLiveSession() -> TerminalSession? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        for s in sessions.values where s.live {
            if responder === s.view || responder.isDescendant(of: s.view) { return s }
        }
        return nil
    }

    // MARK: - Terminal primacy: prime / quiet focus model (Phase 5a, crib §4)

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

    /// Makes `termID` the prime (focused) terminal: re-applies primacy styling
    /// and moves keyboard first responder to its view. Typing always follows the
    /// prime terminal regardless of pointer (crib §6). Used by ⌥tab and ⌘T.
    func setPrime(_ termID: String) {
        guard let s = sessions[termID] else { return }
        primeTermID = termID
        updatePrimacy()
        window?.makeFirstResponder(s.view)
    }
}
