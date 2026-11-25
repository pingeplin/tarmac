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
            let windowNumber = event.windowNumber
            MainActor.assumeIsolated { self?.handlePress(at: point, windowNumber: windowNumber) }
            return event
        }
        // The wheel is routed before it is dispatched: the board takes it
        // unless it is over the selected card's body. The router returns a
        // `Bool` (Sendable) and the event swap stays outside the isolated
        // block (NSEvent isn't Sendable), mirroring `escMonitor`.
        scrollRouteMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let routed = MainActor.assumeIsolated { self?.routeScroll(event) ?? false }
            return routed ? nil : event
        }
        // A pinch always zooms the board.
        magnifyRouteMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            let routed = MainActor.assumeIsolated { self?.routeMagnify(event) ?? false }
            return routed ? nil : event
        }
        installInboxButton()
        connectToDaemon()

        // Layout has happened by the next runloop turn.
        DispatchQueue.main.async { [weak self] in
            self?.viewReady = true
            self?.maybeSpawn()
        }
        startSampling()
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
            modifierFlags: event.modifierFlags.rawValue, isRepeat: event.isARepeat
        )
        let terminal = focusedTerminal
        let focused = terminal.flatMap(session(of:))
        let action = KeyLadder.decide(press, keyFacts(terminal: terminal, focused: focused))
        if let focused { focused.afterRun = KeyLadder.afterRun(was: focused.afterRun, press: press, action: action) }
        afterRestoreCard = KeyLadder.afterRestoreCard(was: afterRestoreCard, press: press, action: action)
        switch action {
        case .passThrough:
            return false
        case .toggleSwitcher:
            if switcherOpen { closeSwitcher() } else { openSwitcher() }
        case .closeSelectedCard:
            closeSwitcher()
            closeInbox()
            closeSelectedCard()
        case .switcherKey:
            return handleSwitcherKey(press)
        case .newTerminal:
            spawnNewTerminal()
        case .flyToSignal:
            guard let target = rootView.offscreenFlyTarget else { return false }
            preFlightViewport = activeBoard.view.viewport
            activeBoard.view.fly(to: target)
        case .esc(let rung):
            climb(rung)
        case .returnKeys:
            // The key is not taken: it is dispatched next, to whoever has
            // the keyboard by then.
            returnKeys()
            return false
        case .runResume:
            if let focused { runResume(focused) }
        case .reopenDead:
            if let focused { reopenDead(focused.termID) }
        case .swallow:
            break
        case .restoreCard(let action):
            chooseOnRestoreCard(action)
        case .toggleInbox:
            toggleInbox()
        case .inboxKey:
            return handleInboxKey(press)
        }
        return true
    }

    private func keyFacts(terminal: TerminalView?, focused: TerminalSession?) -> KeyLadder.Facts {
        let borrow = borrowedCard
        let selectedIsDoc: Bool
        if case .doc = focusedCardID { selectedIsDoc = true } else { selectedIsDoc = false }
        return KeyLadder.Facts(
            composing: terminal?.hasMarkedText() == true,
            switcherOpen: switcherOpen,
            keys: keyHolder(terminal: terminal, documentHoldsKeys: borrow.documentHoldsKeys),
            editingText: typingInDoc,
            hasFlyTarget: rootView.offscreenFlyTarget != nil,
            esc: EscLadder.Facts(
                toastsShowing: rootView.toasts.hasToasts,
                hasPreFlightViewport: preFlightViewport != nil,
                cardBorrowed: borrow.borrowed,
                hasFreshDoc: activeBoard.view.cards.values.contains(where: \.isFreshDoc),
                selectedIsDoc: selectedIsDoc
            ),
            offer: focused.map(keyOffer) ?? .none,
            afterRun: focused?.afterRun ?? false,
            restoreCard: restoreCard?.choices.map(\.action),
            afterRestoreCard: afterRestoreCard,
            inboxOpen: inboxOpen
        )
    }

    /// What the terminal with the keys offers, for the key ladder.
    private func keyOffer(_ s: TerminalSession) -> KeyLadder.Offer {
        if let offer = s.resumeOffer {
            if offer.queued { return .resumeQueued }
            return offer.armed(prime: isPrime(s, on: activeBoard)) ? .resumeArmed : .resumeIdle
        }
        let dead = activeBoard.view.card(.term(s.termID))?.dead == true
        guard dead, s.deadOffer != nil else { return .none }
        return DeadCardOffer.returnKey(endedAt: s.endedAt, now: Date())
    }

    /// The active board's session whose view is `view`.
    private func session(of view: TerminalView) -> TerminalSession? {
        activeBoard.sessions.values.first { $0.view === view }
    }

    /// The terminal view with keyboard focus, live or dead.
    private var focusedTerminal: TerminalView? {
        (window?.firstResponder as? NSView)?.enclosing(TerminalView.self)
    }

    /// Whether the keys go to a text control in a markdown doc's page.
    private var typingInDoc: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return activeBoard.view.cards.values.contains { $0.isTypedInto(through: responder) }
    }

    /// Whether an HTML card is borrowed, and whether its document has keyboard
    /// focus.
    private var borrowedCard: (borrowed: Bool, documentHoldsKeys: Bool) {
        guard let id = borrow.id else { return (false, false) }
        guard let body = activeBoard.view.card(id)?.htmlBody, let responder = window?.firstResponder as? NSView
        else { return (true, false) }
        return (true, body.documentHoldsKeys(responder))
    }

    /// Who holds keyboard focus.
    private func keyHolder(terminal: TerminalView?, documentHoldsKeys: Bool) -> KeyLadder.Keys {
        if documentHoldsKeys { return .document }
        if terminal != nil { return .terminal }
        return consoleHoldsKeys ? .console : .host
    }

    /// Whether the keys are with the console of an HTML card.
    private var consoleHoldsKeys: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return activeBoard.view.cards.values.contains { $0.htmlBody?.consoleHoldsKeys(responder) == true }
    }

    /// Puts the keyboard back where typing goes: the document of the borrowed
    /// card, or the prime terminal.
    private func returnKeys() {
        if let id = borrow.id, let html = activeBoard.view.card(id)?.htmlBody {
            html.focusDocument()
        } else {
            focusPrimeTerminal()
        }
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

    /// ⌘W (`FocusedClose`): a doc card is closed, a terminal is terminated,
    /// and with nothing selected nothing happens.
    private func closeSelectedCard() {
        let kind: FocusedClose.Kind
        var otherLive = 0
        switch focusedCardID {
        case .doc:
            kind = .doc
        case .term(let termID):
            kind = .term
            otherLive = activeBoard.otherLiveTerminals(than: termID)
        case nil:
            kind = .none
        }
        switch FocusedClose.decide(kind: kind, otherLiveTerminals: otherLive) {
        case .noop:
            break
        case .closeDoc:
            if case .doc(let path)? = focusedCardID { closeDocCard(path.string) }
        case .closeTerminal(let replace):
            if case .term(let termID)? = focusedCardID {
                closeTerminal(termID, replace: replace)
            }
        }
    }
}
