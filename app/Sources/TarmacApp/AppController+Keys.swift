import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    func start() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.takeKey(event) ?? false }
            return taken ? nil : event
        }

        // A press selects and raises the card under it before the press is
        // dispatched, so the card is already on top when its content starts
        // tracking the mouse.
        clickFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let point = event.locationInWindow
            MainActor.assumeIsolated { self?.handlePress(at: point) }
            return event
        }
        // Point 2 — pan/scroll routes to the whiteboard unless the pointer is
        // inside the focused card (then its own content scrolls). The router
        // returns a `Bool` (Sendable) and the event swap stays outside the
        // isolated block (NSEvent isn't Sendable), mirroring `escMonitor`.
        scrollRouteMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let routed = MainActor.assumeIsolated { self?.routeScroll(event) ?? false }
            return routed ? nil : event
        }
        // Point 2 — pinch always zooms the whiteboard (a terminal can't pinch).
        magnifyRouteMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            let routed = MainActor.assumeIsolated { self?.routeMagnify(event) ?? false }
            return routed ? nil : event
        }
        connectToDaemon()

        // Layout has happened by the next runloop turn; sizeChanged also flips
        // this, whichever lands first.
        DispatchQueue.main.async { [weak self] in
            self?.viewReady = true
            self?.maybeSpawn()
        }
    }

    // MARK: - Keys

    /// A key-down, seen before the view with keyboard focus gets it
    /// (`KeyLadder`). True means the app took it.
    private func takeKey(_ event: NSEvent) -> Bool {
        // The monitor sees every window's keys, and the board window keeps
        // receiving them after its close button hid it.
        guard let window, event.window === window, window.isVisible else { return false }
        // When the view with keyboard focus is hidden — a culled card's
        // terminal — AppKit makes the window its own first responder, and a
        // window beeps at every key it is left with. The board takes them
        // silently.
        if window.firstResponder === window, rootView.board.window === window {
            window.makeFirstResponder(rootView.board)
        }
        let press = KeyPress(
            keyCode: event.keyCode, characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            modifierFlags: event.modifierFlags.rawValue
        )
        switch KeyLadder.decide(press, keyFacts()) {
        case .passThrough:
            return false
        case .toggleSwitcher:
            if switcherOpen { closeSwitcher() } else { openSwitcher() }
        case .closeSelectedCard:
            closeSwitcher()
            closeSelectedCard()
        case .switcherKey:
            return handleSwitcherKey(press)
        case .copyDocSelection:
            if case .doc(let path)? = focusedCardID {
                activeBoard.view.card(.doc(path))?.docView?.copySelectionToPasteboard()
            }
        case .cycleTerminals:
            cycleTerminals()
        case .newTerminal:
            spawnNewTerminal()
        case .flyToSignal:
            guard let target = rootView.offscreenFlyTarget else { return false }
            preFlightViewport = activeBoard.view.viewport
            activeBoard.view.fly(to: target)
        case .esc(let rung):
            climb(rung)
        }
        return true
    }

    private func keyFacts() -> KeyLadder.Facts {
        let terminal = focusedTerminal
        let borrow = borrowedCard
        let selectedIsDoc: Bool
        if case .doc = focusedCardID { selectedIsDoc = true } else { selectedIsDoc = false }
        return KeyLadder.Facts(
            composing: terminal?.hasMarkedText() == true,
            switcherOpen: switcherOpen,
            keys: borrow.documentHoldsKeys ? .document : terminal != nil ? .terminal : .host,
            hasFlyTarget: rootView.offscreenFlyTarget != nil,
            esc: EscLadder.Facts(
                toastsShowing: rootView.toasts.hasToasts,
                hasPreFlightViewport: preFlightViewport != nil,
                cardBorrowed: borrow.borrowed,
                hasFreshDoc: activeBoard.view.cards.values.contains(where: \.isFreshDoc),
                selectedIsDoc: selectedIsDoc
            )
        )
    }

    /// The terminal view with keyboard focus, live or dead.
    private var focusedTerminal: TerminalView? {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if let terminal = current as? TerminalView { return terminal }
            view = current.superview
        }
        return nil
    }

    /// Whether an HTML card is borrowed, and whether its document has keyboard
    /// focus. Nothing can be borrowed until HTML cards exist.
    private var borrowedCard: (borrowed: Bool, documentHoldsKeys: Bool) {
        (false, false)
    }

    private func climb(_ rung: EscLadder.Rung) {
        switch rung {
        case .clearToasts:
            rootView.toasts.clearAll()
        case .flyBack:
            if let viewport = preFlightViewport { activeBoard.view.flyTo(viewport) }
            preFlightViewport = nil
        case .unborrow:
            escapeHome()
        case .clearFreshDocs:
            _ = clearFreshDocs()
        case .deselectDoc:
            defocus()
        }
    }

    /// Gives a borrowed HTML card back and puts keyboard focus on the prime
    /// terminal.
    func escapeHome() {
        focusPrimeTerminal()
    }

    /// ⌘W (`FocusedClose`): a doc card is closed, a terminal is terminated,
    /// and with nothing selected nothing happens.
    private func closeSelectedCard() {
        let kind: FocusedClose.Kind
        var otherLive = 0
        var dead = false
        switch focusedCardID {
        case .doc:
            kind = .doc
        case .term(let termID):
            kind = .term
            otherLive = activeBoard.otherLiveTerminals(than: termID)
            dead = activeBoard.view.card(.term(termID))?.dead ?? false
        case nil:
            kind = .none
        }
        switch FocusedClose.decide(kind: kind, otherLiveTerminals: otherLive, dead: dead) {
        case .noop:
            break
        case .shelfDoc:
            if case .doc(let path)? = focusedCardID { closeDocCard(path) }
        case .closeTerminal(let replace, let signalClose):
            if case .term(let termID)? = focusedCardID {
                closeTerminal(termID, replace: replace, signalClose: signalClose)
            }
        }
    }
}
