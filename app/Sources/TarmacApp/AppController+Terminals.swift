import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Terminal views

    /// A terminal session reporting to this controller under `termID`, not yet
    /// on a board.
    func makeSession(termID: String) -> TerminalSession {
        TerminalSession(termID: termID, view: makeTerminalView(termID: termID))
    }

    /// Three `TerminalView` hooks stay unset on purpose. `onBell`: the daemon's
    /// `bell` is the observed fact, and a view-side bell would ring twice.
    /// `onClipboardWrite`: a program may not overwrite the user's clipboard
    /// (OSC 52). `onActivity`: what clears a lit bell is bytes leaving for the
    /// PTY and the card becoming prime, not a key or click that sends nothing.
    ///
    /// The view is told the window's display scale because a card on a
    /// backgrounded board spawns its shell before it is ever in the window, and
    /// a cell measured at another scale is a different grid.
    private func makeTerminalView(termID: String) -> TerminalView {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let view: TerminalView
        do {
            view = try TerminalView(frame: frame, theme: .breeze, fontSize: Theme.termFontSize, backingScale: scale)
        } catch {
            fatalError("tarmac: could not create a terminal view: \(error)")
        }
        view.onInput = { [weak self] bytes in self?.terminalDidSend(termID: termID, Data(bytes)) }
        view.onResize = { [weak self] _, _ in self?.terminalSizeChanged(termID: termID) }
        view.onTitleChanged = { [weak self] title in self?.handleTermTitle(termID: termID, title: title) }
        view.onOpenLink = { link in
            guard ExternalLink.isHTTP(href: link), let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }
        view.keyOverride = { chord in
            TermKeyBinding.bytes(
                keyCode: chord.keyCode,
                modifierFlags: TermKeyBinding.modifierFlags(
                    shift: chord.mods.contains(.shift), control: chord.mods.contains(.control),
                    option: chord.mods.contains(.option), command: chord.mods.contains(.command)
                ),
                composing: chord.isComposing
            )
        }
        return view
    }

    // MARK: - Routing

    /// The board a term-keyed daemon frame belongs to. A terminal the index no
    /// longer knows — it exited, or was closed — falls back to the active board.
    private func routeBoard(ofTerm termID: String) -> Board {
        ownerBoard(ofTerm: termID) ?? activeBoard
    }

    /// The session for `termID` wherever its card is. The index forgets a
    /// terminal at exit while its dead card stays, so this looks at the boards.
    private func anySession(_ termID: String) -> (session: TerminalSession, board: Board)? {
        for board in boards.values {
            if let session = board.sessions[termID] { return (session, board) }
        }
        return nil
    }

    // MARK: - Terminal ↔ daemon

    /// A terminal measured a new grid. It may be on a backgrounded board.
    func terminalSizeChanged(termID: String) {
        guard let s = session(ofTerm: termID), s.reachable else { return }
        reportGrid(of: s)
    }

    /// Tells the daemon `s`'s grid when it differs from what it was last told.
    private func reportGrid(of s: TerminalSession) {
        let measured = TermGrid.Size(cols: s.view.cols, rows: s.view.rows)
        guard let grid = TermGrid.resize(measured, onScreen: s.view.window != nil, lastSent: s.sentGrid) else { return }
        s.sentGrid = grid
        client.resize(termID: s.termID, cols: grid.cols, rows: grid.rows)
    }

    /// A terminal whose board was in the background reported nothing while it
    /// was there; catch its PTY up now that the board is shown.
    func syncGrids(on board: Board) {
        for s in board.sessions.values where s.reachable {
            reportGrid(of: s)
        }
    }

    /// Bytes for the PTY: what the user typed, pasted or clicked, and what the
    /// terminal answers a program by itself (DA1, a cursor report, a focus
    /// report). Any of them clears a lit bell. A dead or unspawned terminal has
    /// no PTY to send to.
    func terminalDidSend(termID: String, _ bytes: Data) {
        guard let s = session(ofTerm: termID), s.reachable else { return }
        client.input(termID: termID, bytes: bytes)
        clearBell(termID: termID)
    }

    /// `output` and `scrollback` bytes the gate let through. A ring is the
    /// card's whole history, so the card is cleared first — that keeps a
    /// reconnect's replay from being appended to the history it repeats — and
    /// it is replayed, not fed: its queries were answered when they were live.
    func showOutput(termID: String, _ release: ScrollbackGate.Release) {
        guard let (s, _) = anySession(termID) else { return }
        switch release {
        case .replace(let ring):
            s.view.reset()
            s.view.replay(ring)
        case .append(let chunks):
            // With the link down an answer would queue and reach the program
            // stale, after the reconnect.
            for chunk in chunks {
                if connected { s.feed(chunk) } else { s.view.replay(chunk) }
            }
        }
    }

    // MARK: - Creating and spawning

    /// Puts a terminal card on `board` and asks the daemon for its history. A
    /// card that `needsSpawn` gets its shell from `spawnPending`; one that does
    /// not is bound to a PTY the daemon already runs.
    @discardableResult
    func addTerminal(
        _ termID: String, frame: CardFrame, needsSpawn: Bool, inheritCwdFrom: String? = nil, on board: Board
    ) -> TerminalSession {
        let s = makeSession(termID: termID)
        s.needsSpawn = needsSpawn
        s.inheritCwdFrom = inheritCwdFrom
        board.sessions[termID] = s
        board.sessionOrder.append(termID)
        termIndex.assign(termID: termID, to: board.boardID)
        board.view.setTerminal(termID: termID, s.view, worldFrame: frame)
        let card = board.view.card(.term(termID))
        card?.setTermLabel(s.label)
        card?.setLive(true)
        // The view enters the window at its default frame and measures a grid
        // there. Only once the card has given it its real size does the session
        // go live, so that first grid is never sent to a running PTY.
        card?.layoutSubtreeIfNeeded()
        s.live = true
        // Before any spawn: the daemon answers in order, so the (empty) ring of
        // a terminal it has not spawned yet arrives ahead of that shell's output.
        scrollback.mount(termID)
        if !needsSpawn { reportGrid(of: s) }
        return s
    }

    /// Sends the spawn of every card still waiting for one, once the view has
    /// laid out: a spawn carries the card's grid. A board restored later spawns
    /// from its own restore.
    func maybeSpawn() {
        for board in boards.values {
            spawnPending(on: board)
        }
    }

    /// Nothing is spawned for a board before its restore on this connection:
    /// that restore lists the live terminals, and a shell spawned just ahead of
    /// it would be missing from the list and so be taken for lost.
    func spawnPending(on board: Board) {
        guard connected, viewReady, daemonSession.restoredBoards.contains(board.boardID) else { return }
        for termID in board.sessionOrder {
            guard let s = board.sessions[termID], s.needsSpawn else { continue }
            spawn(s, on: board)
        }
    }

    /// No `cwd` and no `cmd`: the daemon starts `$SHELL` in `$HOME`, or in the
    /// directory of `inherit_cwd_from`. `board_id` files the PTY under its own
    /// board even when that board is in the background.
    private func spawn(_ s: TerminalSession, on board: Board) {
        // The card is laid out at its world size whether or not its board is
        // mounted, so the PTY starts at the card's grid and not at the view's
        // default frame.
        board.view.card(.term(s.termID))?.layoutSubtreeIfNeeded()
        let grid = TermGrid.spawn(cols: s.view.cols, rows: s.view.rows)
        s.needsSpawn = false
        s.sentGrid = grid
        client.spawnTerm(
            termID: s.termID, cols: grid.cols, rows: grid.rows, cwd: nil, cmd: nil,
            boardID: board.boardID, inheritCwdFrom: s.inheritCwdFrom
        )
    }

    /// ⌘T. The new card becomes prime; keyboard focus and the selection stay
    /// where they were.
    func spawnNewTerminal() {
        let board = activeBoard
        // Before its first restore a board is a placeholder the restore rebuilds.
        guard board.didInitialRestore else { return }
        let cards = Array(board.view.cards.values)
        let frame = TermPlacement.newTerminalFrame(
            primeOrigin: board.primeTermCard?.worldFrame.rect.origin,
            existingOrigins: cards.map(\.worldFrame.rect.origin)
        )
        let z = ZOrder.raised(above: cards.map(\.worldFrame.z))
        let candidates = board.sessionOrder.compactMap { id -> CwdInherit.Candidate? in
            guard let s = board.sessions[id] else { return nil }
            return CwdInherit.Candidate(
                termID: id, prime: id == board.primeTermID, live: s.live,
                dead: board.view.card(.term(id))?.dead ?? false
            )
        }
        let s = addTerminal(
            BootTerminal.mint(), frame: CardFrame(rect: frame, z: z), needsSpawn: true,
            inheritCwdFrom: CwdInherit.source(in: candidates), on: board
        )
        board.primeTermID = s.termID
        updatePrimacy(on: board)
        spawnPending(on: board)
        persistLayout(for: board)
    }

    /// A fresh shell in the place of the board's last live terminal, which just
    /// went away: same frame and z, a new id, prime.
    private func replaceTerminal(at frame: CardFrame, on board: Board) {
        let s = addTerminal(BootTerminal.mint(), frame: frame, needsSpawn: true, on: board)
        board.primeTermID = s.termID
        spawnPending(on: board)
    }

    // MARK: - Exit and close

    /// A shell exited (`TermExit.decide`): a failure holds the card open dead,
    /// a clean exit removes it, and the board's last live terminal is replaced.
    /// An exit for a card that is already gone is ignored.
    func handleExit(termID: String, code: Int?) {
        let board = routeBoard(ofTerm: termID)
        guard let s = board.sessions[termID], let card = board.view.card(.term(termID)) else { return }
        if let title = TermExitToast.title(code: code) {
            rootView.toasts.show(icon: TermExitToast.icon, title: title, body: nil)
        }
        let frame = card.worldFrame
        switch TermExit.decide(code: code, otherLiveTerminals: board.otherLiveTerminals(than: termID)) {
        case .holdOpen:
            holdOpen(s, on: board)
            board.reassignPrime()
        case .remove:
            removeTerminalCard(termID, on: board)
            board.reassignPrime()
        case .removeAndReplace:
            removeTerminalCard(termID, on: board)
            replaceTerminal(at: frame, on: board)
        }
        termIndex.remove(termID: termID)
        updatePrimacy(on: board)
        persistLayout(for: board)
        refreshSwitcherIfOpen()
    }

    /// The card stays on the board as a dead placeholder: it keeps its label
    /// and its screen, takes no input, and is never persisted. A scrollback
    /// wait is left running, so a reply already in flight, or the deadline,
    /// still lands on the dead card.
    func holdOpen(_ s: TerminalSession, on board: Board) {
        s.live = false
        s.needsSpawn = false
        s.procName = nil
        s.bellAt = nil
        board.view.card(.term(s.termID))?.setExited()
        board.view.signalsChanged()
    }

    /// Takes a terminal card off `board`, releasing its held output and any
    /// scrollback wait. Nothing is sent to the daemon. Keyboard focus is not
    /// handed to another terminal: if the card held it, the board takes it.
    private func removeTerminalCard(_ termID: String, on board: Board) {
        scrollback.unmount(termID)
        let isActive = board === activeBoard
        if isActive, focusedCardID == .term(termID) { focusedCardID = nil }
        let heldFocus = isActive && board.sessions[termID].map { window?.firstResponder === $0.view } == true
        board.sessions[termID] = nil
        board.sessionOrder.removeAll { $0 == termID }
        termIndex.remove(termID: termID)
        board.view.removeCard(id: .term(termID))
        board.view.signalsChanged()
        if heldFocus { window?.makeFirstResponder(rootView.board) }
    }

    /// ⌘W on a terminal card (`FocusedClose.decide`). The card goes at once, so
    /// the exit the daemon reports for the SIGHUP finds no card and is ignored.
    func closeTerminal(_ termID: String, replace: Bool, signalClose: Bool) {
        let board = activeBoard
        guard let card = board.view.card(.term(termID)) else { return }
        let frame = card.worldFrame
        if signalClose { client.termClose(termID: termID) }
        removeTerminalCard(termID, on: board)
        if replace {
            replaceTerminal(at: frame, on: board)
        } else {
            board.reassignPrime()
        }
        updatePrimacy(on: board)
        persistLayout(for: board)
        refreshSwitcherIfOpen()
    }

    // MARK: - Connection

    /// The daemon connection dropped. Cards are left as they are — the next
    /// restore reconciles them — but no scrollback request will be answered now.
    func terminalsLostConnection() {
        scrollback.socketLost()
        daemonSession = DaemonSession()
    }

    // MARK: - Label, bell

    /// `term_proc`: the foreground process name becomes the label.
    func handleTermProc(termID: String, name: String) {
        let board = routeBoard(ofTerm: termID)
        guard let s = board.sessions[termID] else { return }
        s.procName = name
        setLabel(TermLabel.afterProc(name), of: s, on: board)
    }

    /// A program set its OSC 0/1/2 title.
    func handleTermTitle(termID: String, title: String?) {
        guard let (s, board) = anySession(termID) else { return }
        setLabel(TermLabel.afterTitle(title, current: s.label), of: s, on: board)
    }

    private func setLabel(_ label: String, of s: TerminalSession, on board: Board) {
        guard label != s.label else { return }
        s.label = label
        board.view.card(.term(s.termID))?.setTermLabel(label)
        board.view.signalsChanged()
        for path in board.boardDocPaths {
            guard let docCard = board.view.card(.doc(path)) else { continue }
            docCard.setOwnerChip(ownerChipLabel(for: docCard, on: board))
        }
        refreshSwitcherIfOpen()
    }

    /// `bell`: light the card amber and note when.
    func handleBell(termID: String) {
        let board = routeBoard(ofTerm: termID)
        guard let s = board.sessions[termID], let card = board.view.card(.term(termID)), !card.dead else { return }
        s.bellAt = Date()
        card.setBell(true)
        board.view.signalsChanged()
        refreshSwitcherIfOpen()
    }

    /// Puts out a lit bell; a no-op when it is not lit. Called for any bytes
    /// the terminal sends, and when it becomes prime by a press on its card or
    /// by ⌥Tab.
    func clearBell(termID: String) {
        guard let (s, board) = anySession(termID),
              let card = board.view.card(.term(termID)), card.bellActive else { return }
        s.bellAt = nil
        card.setBell(false)
        board.view.signalsChanged()
        refreshSwitcherIfOpen()
    }

    // MARK: - Offscreen hints

    /// Builds the offscreen-hint models for every signalling card: bell →
    /// `label · HH:MM` (when it rang); live → the label. The board decides which
    /// are actually offscreen and where they pin. Priority orders the Return
    /// target (bell outranks live; among same, most-recent wins by z).
    func offscreenHints() -> [OffscreenHints.Hint] {
        var hints: [OffscreenHints.Hint] = []
        for (id, card) in activeBoard.view.cards {
            let signal = card.signal
            guard signal != .none else { continue }
            let viewCenter = CGPoint(x: card.frame.midX, y: card.frame.midY)
            let label: String
            switch id {
            case .term(let tid):
                let name = sessions[tid]?.label ?? ""
                label = signal == .bell ? "\(name) · \(hhmm(sessions[tid]?.bellAt ?? Date()))" : name
            case .doc(let path):
                let base = store.doc(for: path)?.fileName ?? (path as NSString).lastPathComponent
                label = signal == .bell ? "\(base) · \(hhmm(Date()))" : base
            }
            let priority = (signal == .bell ? 1000 : 0) + card.worldFrame.z
            hints.append(OffscreenHints.Hint(cardID: id, centerView: viewCenter, signal: signal, label: label, priority: priority))
        }
        return hints
    }

    private func hhmm(_ date: Date) -> String {
        Self.hhmmFormatter.string(from: date)
    }

    // MARK: - ⌥Tab

    /// Moves prime and keyboard focus to the next live terminal in card order
    /// (wrapping), starting from the terminal that holds keyboard focus, and
    /// shows the HUD. The terminal it lands on has its bell cleared.
    func cycleTerminals() {
        reconcilePrimeToFocus()
        let order = TermCycle.order(activeBoard.cycleTerms)
        guard let next = TermCycle.step(order: order, from: primeTermID, .next) else { return }
        setPrime(next)
        clearBell(termID: next)
        let labels = order.map { id -> String in
            let label = sessions[id]?.label ?? ""
            return label.isEmpty ? TermLabel.initial : label
        }
        rootView.cycleHUD.show(labels: labels, activeIndex: order.firstIndex(of: next) ?? 0)
    }
}
