import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    /// P5.4: drop a deleted board locally — its `Board` (cards + detached/live
    /// sessions + view) and every term→board routing entry. Never the active
    /// board (which must always exist; the daemon fixes active before a delete's
    /// board_list arrives). Its ptys were already killed daemon-side; any in-flight
    /// `exit` for them is then ignored (their owner no longer resolves), and the
    /// board's backgrounded view (never mounted) deallocates with the `Board`.
    func removeBoard(_ id: String) {
        guard id != activeBoardID, boards[id] != nil else { return }
        for termID in termIndex.terms(of: id) {
            scrollback.unmount(termID)
        }
        termIndex.removeBoard(id)
        boards[id] = nil
    }

    /// Dims the traffic lights while the ⌘K switcher is open
    /// (B5 `dim` titlebar), restoring them on close.
    private func setTitlebarDim(_ dim: Bool) {
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.alphaValue = dim ? 0.4 : 1
        }
    }

    /// Mounts `board`'s view in RootView and (re)binds the controller-owned
    /// per-board callbacks to it: the provenance edge label (crib §8) and the
    /// committed-layout persist. The persist closure captures the board's id (by
    /// value, no retain cycle), so a committed move/resize/zoom/pan persists THAT
    /// board — stamped with its `board_id` — even if a stray callback fires after
    /// it stops being active (it's then dropped by the active-board guard). Called
    /// at boot and on every switch-arrive.
    func mount(_ board: Board) {
        rootView.mountBoard(board.view)
        board.view.edgeLabelProvider = { [weak self] id in self?.edgeLabel(for: id) }
        let bid = board.boardID
        // Pan fires onLayoutChanged per scroll event; coalesce the persist on a
        // short trailing timer (fix #2) so a continuous pan does one snapshot+IPC
        // when it settles, not one per delta. Flushed eagerly on switch-away /
        // resign-active / terminate so the last position is never dropped.
        board.view.onLayoutChanged = { [weak self] _ in self?.schedulePersist(boardID: bid) }
        board.view.onCardClose = { [weak self] id in
            guard case .doc(let path) = id else { return }
            self?.closeDocCard(path)
        }
    }

    // MARK: - ⌘K switcher

    /// Opens the switcher on the active board's row. The switcher holds first
    /// responder while it is up: the menu's Paste, Copy and Select All go to
    /// the first responder, and must not land in the terminal behind it.
    func openSwitcher() {
        guard !switcherOpen else { return }
        switcherOpen = true
        switcherState = SwitcherKeys.opened(summaries: boardSummaries(), active: activeBoardID)
        rebuildSwitcherRows()
        // Laid out before it is rendered, so scrolling the selected row into
        // view runs against the panel's real bounds.
        rootView.setSwitcherVisible(true)
        rootView.layoutSubtreeIfNeeded()
        renderSwitcher()
        rootView.boardSwitcher.takeKeys()
        setTitlebarDim(true)
    }

    /// Re-renders an open switcher after a board, bell or exit changed.
    func refreshSwitcherIfOpen() {
        guard switcherOpen else { return }
        rebuildSwitcherRows()
        renderSwitcher()
    }

    /// Closes the switcher and hands keyboard focus back to the view that had
    /// it when the switcher opened.
    func closeSwitcher() {
        guard switcherOpen else { return }
        switcherOpen = false
        switcherState = SwitcherKeys.State()
        // Before the view is hidden: hiding the first responder hands the keys
        // to the window, and there would be nothing left to give back.
        rootView.boardSwitcher.returnKeys(fallback: rootView.board)
        rootView.setSwitcherVisible(false)
        setTitlebarDim(false)
    }

    func rebuildSwitcherRows() {
        let rows = BoardSwitcher.rows(summaries: boardSummaries(), active: activeBoardID, filter: switcherState.filter)
        switcherRows = rows.map { row in
            SwitcherRowVM(row: row, thumb: boards[row.boardID]?.view.minimapItems ?? [])
        }
    }

    func renderSwitcher() {
        let state = switcherState
        let deleteTarget = state.confirmingDelete && switcherRows.indices.contains(state.selected)
            ? switcherRows[state.selected].row.display : nil
        rootView.boardSwitcher.render(
            rows: switcherRows, selected: state.selected, query: state.filter,
            editing: state.editing, editBuffer: state.editBuffer,
            confirmingDelete: state.confirmingDelete, deleteTarget: deleteTarget
        )
    }

    /// One summary per board in the daemon's order. Until the first
    /// `board_list` arrives the active board stands alone, so the switcher
    /// never opens onto an empty list.
    private func boardSummaries() -> [BoardSwitcher.BoardSummary] {
        var summaries = boardMetas.map {
            boardSummary(forBoardID: $0.boardID, name: $0.name, daemonRunning: $0.running)
        }
        if !summaries.contains(where: { $0.boardID == activeBoardID }) {
            summaries.insert(
                boardSummary(forBoardID: activeBoardID, name: activeBoard.name, daemonRunning: nil),
                at: 0
            )
        }
        return summaries
    }

    private func boardSummary(
        forBoardID id: String, name: String?, daemonRunning: Int?
    ) -> BoardSwitcher.BoardSummary {
        let board = boards[id]
        let terms = board?.sessionOrder.compactMap { termID -> BoardSwitcher.TermFact? in
            guard let session = board?.sessions[termID] else { return nil }
            return BoardSwitcher.TermFact(
                running: session.live, bell: board?.view.card(.term(termID))?.bellActive ?? false
            )
        }
        return BoardSwitcher.summary(
            boardID: id, name: name, visited: board?.didInitialRestore ?? false, terms: terms ?? [],
            cards: board?.view.cards.count ?? 0, daemonRunning: daemonRunning
        )
    }

    /// A key the open switcher owns (`SwitcherKeys`). False leaves it for the
    /// menu.
    func handleSwitcherKey(_ press: KeyPress) -> Bool {
        let (state, effect) = SwitcherKeys.handle(
            press, state: switcherState, summaries: boardSummaries(), active: activeBoardID,
            boardCount: max(boardMetas.count, boards.count)
        )
        switch effect {
        case .leaveForMenu:
            return false
        case .none:
            switcherState = state
            refreshSwitcherIfOpen()
        case .close:
            closeSwitcher()
        case .switchTo(let boardID):
            closeSwitcher()
            performSwitch(to: boardID)
        case .create:
            // The daemon makes the new board active and says so in a
            // `board_list`, which is what the app follows.
            client.boardCreate()
            closeSwitcher()
        case .rename(let boardID, let name):
            switcherState = state
            client.boardRename(boardID: boardID, name: name)
            refreshSwitcherIfOpen()
        case .delete(let boardID):
            client.boardDelete(boardID: boardID)
            closeSwitcher()
        }
        return true
    }

    /// A row was clicked.
    func switcherPickRow(_ index: Int) {
        guard switcherRows.indices.contains(index) else { return }
        let boardID = switcherRows[index].row.boardID
        closeSwitcher()
        performSwitch(to: boardID)
    }

    // MARK: - Board switching (M3 P3)

    /// App-initiated switch to `targetID`: detach the current board and tell the
    /// daemon, which replies with `board_list` + the target's `restore`; the
    /// arrive path (`applyRestore`) mounts + (first visit) builds it. No-op if
    /// already there or the target is unknown. (P4's ⌘K routes here too.)
    private func performSwitch(to targetID: String) {
        guard targetID != activeBoardID, boardMetas.contains(where: { $0.boardID == targetID }) else { return }
        beginArrivingSwitch(to: targetID)
        client.boardSwitch(boardID: targetID)
    }

    /// The LEAVE half of a switch, shared by an app-initiated switch and the
    /// daemon-initiated one (`board_create` auto-activates the new board, so the
    /// app follows on `board_list`). Detaches the current board and makes
    /// `targetID` active + minted, ready for its restore to mount it. Does NOT
    /// send `board_switch` (the caller does, or the daemon already switched).
    func beginArrivingSwitch(to targetID: String) {
        guard let meta = boardMetas.first(where: { $0.boardID == targetID }) else { return }
        // Flush a settling pan's debounced persist while the leaving board is still
        // active (`switching` false, still `activeBoard`), or its guard would drop
        // it once we switch (fix #2).
        flushPendingPersist()
        closeSwitcher()
        switching = true
        // First responder comes off the leaving board's views before the view
        // is swapped; a stale one would leave the arrived board unfocused.
        // Target nil, not rootView.board, which is about to be swapped.
        window?.makeFirstResponder(nil)
        // Clear card focus so the arrived board starts in board-navigation mode
        // (point 2). Otherwise a stale focusedCardID could collide with a same-id
        // card on the target board (doc cards key on path, shared across boards)
        // and wrongly capture its scroll.
        focusedCardID = nil
        rootView.unmountBoard()
        // P5.5: suspend the leaving board's doc web views (free their web content
        // processes) AFTER it is unmounted (so a still-visible view never flashes
        // about:blank) and while it is still the active board. Terminals are
        // untouched — they keep being fed live in the background (P5.2).
        boards[activeBoardID]?.view.cards.values.forEach { $0.suspendDoc() }
        // The target must exist before it becomes active (`activeBoard` force-
        // unwraps); a first visit mints its BoardView + boot session here.
        if boards[targetID] == nil { _ = mintBoard(id: targetID, name: meta.name) }
        activeBoardID = targetID
    }

    /// Lazily creates a board the daemon told us about, on first activation: its
    /// own BoardView + a boot session (kept prime, registered in the term index,
    /// store wired), mirroring board-0's boot. The view is mounted by the
    /// arrive path, and the boot pty is spawned there (`maybeSpawn`).
    @discardableResult
    private func mintBoard(id: String, name: String?) -> Board {
        let board = Board(boardID: id, name: name, view: BoardView())
        let bootTermID = BootTerminal.mint()
        let boot = makeSession(termID: bootTermID)
        board.sessions[bootTermID] = boot
        board.sessionOrder = [bootTermID]
        board.primeTermID = bootTermID
        termIndex.assign(termID: bootTermID, to: id)
        board.view.setTerminal(termID: bootTermID, boot.view, worldFrame: Place.termFrame)
        wireStore(board)
        boards[id] = board
        return board
    }

    /// The ARRIVE half: the target's view is mounted and (on a first visit) its
    /// cards/terminals built; now re-establish focus on the arrived board,
    /// AFTER its card tree is laid out (crit B3 / S1), and end the transient.
    func finishArrive(on board: Board) {
        rootView.layoutSubtreeIfNeeded()
        // P5.5: resume the arriving board's doc web views AFTER layout (so the
        // reloaded template lays out at card size, not 0×0). No-op for a board
        // whose docs were never suspended (e.g. its first arrive), since
        // DocWebView.resume guards on `suspended`.
        board.view.cards.values.forEach { $0.resumeDoc() }
        let home: NSView = board.primeTerminalView ?? rootView.board
        // A switcher opened while the board was on its way keeps the keys, and
        // hands them to the arrived board when it closes.
        if switcherOpen {
            rootView.boardSwitcher.keysOwner = home
        } else {
            window?.makeFirstResponder(home)
        }
        updatePrimacy()
        switching = false
    }
}
