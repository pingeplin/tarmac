import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Click-to-focus + gesture routing (points 2 & 3)

    /// The deepest view under a window-space point, or nil. `window.contentView`
    /// is the RootView (`main.swift`), and `locationInWindow` is already in the
    /// window's base coordinate system (= the content view's superview coords),
    /// so this is the standard hit test for a monitored event.
    private func hitView(at point: NSPoint) -> NSView? {
        window?.contentView?.hitTest(point)
    }

    /// Walks up from a hit view to the `CardView` that contains it (header, clip,
    /// terminal/doc body, or a resize handle all live inside one), or nil
    /// if the point is on the bare board / an overlay.
    private func enclosingCard(_ view: NSView?) -> CardView? {
        var v = view
        while let cur = v {
            if let card = cur as? CardView { return card }
            v = cur.superview
        }
        return nil
    }

    /// Point 3: a single click on a card focuses it. A click on the empty board
    /// background defocuses (board-navigation mode resumes). Clicks landing on the
    /// overlays (switcher / minimap / status bar) are left alone. Runs one tick
    /// after the click has dispatched.
    func handleClickFocus(at point: NSPoint) {
        guard !switcherOpen, window?.isKeyWindow == true else { return }
        guard let hit = hitView(at: point), hit.isDescendant(of: rootView.board) else { return }
        // The viewport-pinned close ✕ is a board subview but belongs to no card; a
        // click on it already routed to close-the-doc via its own handler, so don't
        // mistake it for a bare-board click and defocus the (possibly other) card.
        if hit.isDescendant(of: rootView.board.floatingClose) { return }
        if let card = enclosingCard(hit) {
            focus(card.id)
        } else {
            defocus()
        }
    }

    /// Makes `id` the focused card: brings it to the front, arms its resize
    /// handles (a plain focus now shows handles — the card's own `focused` state
    /// drives them), and for a live terminal makes it prime (keyboard + accent
    /// border + darker header — the focus indicator). Clears any stale selection
    /// left on a *different* card by an earlier header grab, so only the focused
    /// card wears handles.
    private func focus(_ id: CardID) {
        guard activeBoard.view.card(id) != nil else { return }
        if activeBoard.view.selectedID != id { activeBoard.view.select(nil) }
        focusedCardID = id
        activeBoard.view.bringToFront(id)
        persistLayout()
        if case let .term(termID) = id, sessions[termID]?.live == true {
            setPrime(termID)   // re-primes AND recomputes the focus edge via updatePrimacy
            clearBell(termID: termID)
        } else {
            updatePrimacy()    // doc / dead: no re-prime, but paint the focus edge
        }
    }

    /// Clears card focus so pan / pinch / scroll drive the board (point 2). Does
    /// not touch the prime terminal — typing still follows it (terminal primacy).
    func defocus() {
        guard focusedCardID != nil || activeBoard.view.selectedID != nil else { return }
        focusedCardID = nil
        activeBoard.view.select(nil)
        updatePrimacy()   // clear the focus edge off the previously-focused card
    }

    /// Point 2: a scroll/pan routes to the whiteboard — pans the board and returns
    /// `true` to swallow the event — UNLESS the pointer is inside the focused card,
    /// in which case it returns `false` so the event passes through to that card's
    /// own content (terminal scrollback / doc scroll). Events over the overlays or
    /// outside the board return `false` (left untouched).
    func routeScroll(_ event: NSEvent) -> Bool {
        guard !switcherOpen else { return false }
        guard let hit = hitView(at: event.locationInWindow), hit.isDescendant(of: rootView.board) else { return false }
        // The viewport-pinned close ✕ floats over the doc it closes; a scroll there
        // must not pan the board out from under the doc being read. Swallow it (the
        // ✕ is a small corner control — scrolling it is a no-op, not a board pan).
        if hit.isDescendant(of: activeBoard.view.floatingClose) { return true }
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
        // Suppress board zoom while a card move/resize is in flight — changing the
        // zoom mid-gesture would invalidate the card's snapshot pointer→world
        // scale. Swallow it (do nothing) rather than let it fall through to a zoom.
        if rootView.board.isGesturing { return true }
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

    /// Applies the prime/quiet card states (crib §4): the prime terminal card
    /// (focused terminal: `#5a626a` border, `#3a4046` header, deeper shadow) is
    /// raised and every other card — docs and non-prime terminals — is quiet
    /// (opacity 0.8). Prime follows the ⌥tab cycle / ⌘T (Phase 5b); a dead
    /// terminal card keeps its own dim and never reads as prime. Nothing is prime
    /// when no terminal is live.
    func updatePrimacy(on board: Board? = nil) {
        let b = board ?? activeBoard
        let primeID: CardID? = b.hasLivePrime ? b.primeTermID.map(CardID.term) : nil
        // Focus (the scroll-active card) is an active-board-only concept — a
        // background board never shows the focus edge, mirroring the board-switch
        // clear at beginArrivingSwitch. This is the single loop where all three
        // attention visuals (prime, quiet, focused) recompute per card.
        let focusID: CardID? = (b === activeBoard) ? focusedCardID : nil
        for (id, card) in b.view.cards {
            let isPrime = (id == primeID)
            card.setPrime(isPrime)
            // A card is quiet only while some terminal is prime and it isn't it.
            card.setQuiet(primeID != nil && !isPrime)
            card.setFocused(id == focusID)
        }
        // Focus drives whether a doc's in-card ✕ is shown, and a focus change does
        // not reproject — so re-evaluate the viewport-pinned twin here too.
        b.view.refreshFloatingClose()
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
