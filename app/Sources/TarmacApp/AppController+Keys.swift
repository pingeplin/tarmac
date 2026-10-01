import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    func start() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only the four "intent" modifiers. macOS sets .function + .numericPad
            // on arrow keys, so masking with the full .deviceIndependentFlagsMask
            // made `mods == [.control, .command]` impossible for ⌃⌘→ (its raw mods
            // are [.control, .command, .function, .numericPad]) — the cycle key
            // silently never fired. Masking to these four also drops .capsLock,
            // so the no-modifier / single-modifier checks below work with caps on.
            let mods = event.modifierFlags.intersection([.control, .command, .option, .shift])
            let isEsc = event.keyCode == 53
            // Bare Return (no modifiers) flies to an offscreen signal.
            let isReturn = event.keyCode == 36 && mods.isEmpty
            // ⌥tab (tab = keyCode 48 with the Option modifier, ignoring caps lock)
            // cycles the focused terminal among terminal cards + shows the HUD
            // (crib §6). With one terminal this is a no-op cycle (single HUD item).
            let isOptTab = event.keyCode == 48 && mods == .option
            // ⌘T (T = keyCode 17) spawns a new terminal card (Phase 5b).
            let isCmdT = event.keyCode == 17 && mods == .command
            // M3 P4: ⌘K (K = keyCode 40) opens the boards switcher. While the
            // switcher is open every keystroke routes through it (handled first
            // below), so the board behind stays inert.
            let isCmdK = event.keyCode == 40 && mods == .command
            // ⌘C (C = keyCode 8): copy. Handled specially only when a doc card is
            // focused (below); otherwise it falls through to the responder chain so
            // the prime terminal's own copy still works.
            let isCmdC = event.keyCode == 8 && mods == .command
            // ⌘W (W = keyCode 13, issue #15) closes the focused card. Always
            // swallowed so it never reaches the window-close menu.
            let isCmdW = event.keyCode == 13 && mods == .command
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                // A window hidden by its close button still has a key monitor;
                // a board nobody can see takes no shortcuts.
                guard let self, self.window?.isVisible == true else { return false }
                // While the ⌘K switcher is open it owns the keyboard: route every
                // key to it (filter / move / open / create) before anything else,
                // so the board behind stays inert.
                if self.switcherOpen {
                    return self.handleSwitcherKey(event, mods: mods)
                }
                // Every keystroke passes through here before its view handles it,
                // so keep prime in sync with the terminal the user is typing in
                // (clicking a non-prime terminal made it first responder without
                // updating primeTermID). Cheap: only re-styles on an actual change.
                self.reconcilePrimeToFocus()
                // ⌘C for a doc card: it hosts a non-focusable WKWebView (crib §9 —
                // a doc click must not pull keyboard focus off the prime terminal),
                // so the standard copy: never reaches it via the responder chain and
                // ⌘C silently does nothing. Route it explicitly to the focused doc
                // card. When none is focused this is skipped, so ⌘C still reaches
                // the prime terminal / responder chain unchanged.
                if isCmdC, case .doc(let path)? = self.focusedCardID,
                   let docView = self.activeBoard.view.card(.doc(path))?.docView {
                    docView.copySelectionToPasteboard()
                    return true
                }
                if isCmdK {
                    self.openSwitcher()
                    return true
                }
                if isCmdT {
                    self.spawnNewTerminal()
                    return true
                }
                // ⌘W closes the focused card (issue #15). Always swallowed — even
                // with nothing focused (a no-op) — so it never closes the window.
                if isCmdW {
                    self.closeFocusedCard()
                    return true
                }
                if isOptTab {
                    self.cycleTerminals()
                    return true
                }
                // Return, when the board (not the terminal) holds focus and an
                // offscreen signal is waiting, flies the viewport to it (crib §6).
                // Gated on board focus so the shell's Enter key is never hijacked
                // while typing. With nowhere to fly the key goes on to the board,
                // which takes it silently.
                if isReturn, self.boardHasFocus(), let target = self.rootView.offscreenFlyTarget {
                    self.preFlightViewport = self.activeBoard.view.viewport
                    self.activeBoard.view.fly(to: target)
                    return true
                }
                guard isEsc else { return false }
                // esc after a Return flight flies the viewport back (crib §6).
                if let prev = self.preFlightViewport {
                    self.preFlightViewport = nil
                    self.activeBoard.view.flyTo(prev)
                    return true
                }
                if self.rootView.toasts.hasToasts {
                    self.rootView.toasts.clearAll()
                    return true
                }
                if self.clearFreshDocs() {
                    return true
                }
                // With the toasts dismissed, esc on a focused DOC card
                // drops focus — the doc stays on the board; removal
                // is the ✕ / ⌘W (issue #15). A focused TERMINAL is left for the
                // responder chain so esc still reaches the program (agent-interrupt
                // / vim). Routed through EscFocusAction so the rule is unit-tested.
                let focusedIsDoc: Bool
                if case .doc = self.focusedCardID { focusedIsDoc = true } else { focusedIsDoc = false }
                if EscFocusAction.forFocusedDoc(focusedIsDoc) == .defocus {
                    self.defocus()
                    return true
                }
                return false
            }
            return swallowed ? nil : event
        }

        // A press selects and raises the card under it before the press is
        // dispatched, so the card is already on top when its content starts
        // tracking the mouse.
        clickFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let point = event.locationInWindow
            MainActor.assumeIsolated { self?.handlePress(at: point) }
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
        connectToDaemon()

        // Layout has happened by the next runloop turn; sizeChanged also flips
        // this, whichever lands first.
        DispatchQueue.main.async { [weak self] in
            self?.viewReady = true
            self?.maybeSpawn()
        }
    }

    /// ⌘W closes the focused card (issue #15), routed through `FocusedClose`: a doc
    /// card is removed from the board; a terminal is terminated; nothing focused
    /// is a no-op. The keyboard twin of the header ✕, scoped to the one card the
    /// user is looking at.
    private func closeFocusedCard() {
        let kind: FocusedClose.Kind
        var otherLive = 0
        var dead = false
        switch focusedCardID {
        case .doc:
            kind = .doc
        case .term(let termID):
            kind = .term
            otherLive = activeBoard.sessions.filter { $0.key != termID && $0.value.live }.count
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

    /// True when keyboard focus is on the board rather than the terminal — so a
    /// bare Return triggers the offscreen flight instead of the shell's Enter
    /// (crib §6 focus model). The terminal is the default first responder; the
    /// board takes focus only when the user clicks its background.
    private func boardHasFocus() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        // Any terminal view (or a descendant) holding focus means a terminal —
        // not the board — is focused, so Return belongs to the shell.
        for s in sessions.values {
            if responder === s.view { return false }
            if let view = responder as? NSView, view.isDescendant(of: s.view) { return false }
        }
        // The board view itself (or a non-terminal board descendant) is focused.
        if let view = responder as? NSView, view.isDescendant(of: rootView.board) { return true }
        return responder === rootView.board
    }
}
