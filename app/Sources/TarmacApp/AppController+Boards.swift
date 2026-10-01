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

    /// Dims the titlebar chip + the traffic lights while the ⌘K switcher is open
    /// (B5 `dim` titlebar), restoring them on close.
    private func setTitlebarDim(_ dim: Bool) {
        titleChip.alphaValue = dim ? 0.4 : 1
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

    // MARK: - ⌘K boards switcher (M3 P4)

    /// Opens the switcher: reset the filter, build the rows, default-select the
    /// active board's row, veil the board, and render. Takes first responder so
    /// the board behind is inert to first-responder-routed menu keys (⌘C/⌘V/⌘A),
    /// which are dispatched ahead of the global key monitor.
    func openSwitcher() {
        guard !switcherOpen else { return }
        switcherOpen = true
        switcherFilter = ""
        rebuildSwitcherRows()
        switcherSelected = switcherRows.firstIndex { $0.row.isActive } ?? 0
        // Make the overlay visible and lay it out BEFORE rendering, so the row's
        // scroll-selected-into-view runs against the real panel bounds (with 16
        // boards the active row can be far down the scrolled list).
        rootView.setSwitcherVisible(true)
        rootView.layoutSubtreeIfNeeded()
        renderSwitcher()
        window?.makeFirstResponder(rootView.boardSwitcher)
        setTitlebarDim(true)
    }

    /// Re-renders an open switcher after a live signal change (bell / agent
    /// start-stop / exit / disconnect) so its counts, thumbnail colors, and live
    /// glyph track reality while the panel is up. No-op when closed.
    func refreshSwitcherIfOpen() {
        guard switcherOpen else { return }
        rebuildSwitcherRows()
        renderSwitcher()
    }

    /// Closes the switcher. `restoreFocus` puts first responder back on the active
    /// board's prime terminal — skipped when a switch/create is about to run
    /// (that path re-establishes focus on arrive).
    func closeSwitcher(restoreFocus: Bool = true) {
        guard switcherOpen else { return }
        switcherOpen = false
        // P5.4: drop any transient rename/confirm state so a re-open starts clean.
        switcherEditing = false
        switcherConfirmingDelete = false
        rootView.setSwitcherVisible(false)
        setTitlebarDim(false)
        if restoreFocus { focusPrimeTerminal() }
    }

    /// Rebuilds the visible rows from the live board facts + the current filter,
    /// re-clamping the selection.
    func rebuildSwitcherRows() {
        let rows = BoardSwitcher.rows(summaries: boardSummaries(), active: activeBoardID, filter: switcherFilter)
        switcherRows = rows.map { row in
            SwitcherRowVM(row: row, thumb: boards[row.boardID]?.view.minimapItems ?? [])
        }
        switcherSelected = BoardSwitcher.clampSelection(switcherSelected, count: switcherRows.count)
    }

    func renderSwitcher() {
        let deleteTarget = switcherConfirmingDelete && switcherRows.indices.contains(switcherSelected)
            ? switcherRows[switcherSelected].row.display : nil
        rootView.boardSwitcher.render(
            rows: switcherRows, selected: switcherSelected, query: switcherFilter,
            editing: switcherEditing, editBuffer: switcherEditBuffer,
            confirmingDelete: switcherConfirmingDelete, deleteTarget: deleteTarget
        )
    }

    /// Per-board facts for the switcher. Counts derive from each board's own card
    /// signals (accurate for the active + any visited board — their cards + live
    /// terminal views stay alive while backgrounded). A never-visited board has
    /// no app-side view yet, so it reports 0 cards / not-live until first restore.
    /// If `board_list` has not arrived yet (the connect window), the active board
    /// — always minted + mounted locally — is synthesized so the switcher never
    /// opens onto an empty list.
    private func boardSummaries() -> [BoardSwitcher.BoardSummary] {
        var summaries = boardMetas.map {
            boardSummary(forBoardID: $0.boardID, name: $0.name, daemonRunning: $0.running)
        }
        if !summaries.contains(where: { $0.boardID == activeBoardID }) {
            // The active board is always minted + mounted locally (visited), so
            // its daemon running count is unused — pass nil.
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
        var localRunning = 0, bell = 0, cards = 0, localLive = false
        let visited = boards[id] != nil
        if let board = boards[id] {
            for card in board.view.cards.values {
                cards += 1
                switch card.signal {
                case .live: localRunning += 1
                case .bell: bell += 1
                case .none: break
                }
            }
            localLive = board.sessions.values.contains { $0.live }
        }
        // P5: for a never-visited board the daemon's live-pty count is the only
        // honest liveness; for a visited board the local signals win (no flicker).
        let (running, live) = BoardSwitcher.liveness(
            visited: visited, localRunning: localRunning, localIsLive: localLive,
            daemonRunning: daemonRunning
        )
        return BoardSwitcher.BoardSummary(
            boardID: id, name: name, running: running, bell: bell, cards: cards, isLive: live
        )
    }

    // Key handling while the switcher is open (called from the global monitor).
    func handleSwitcherKey(_ event: NSEvent, mods: NSEvent.ModifierFlags) -> Bool {
        let kc = event.keyCode
        // P5.4: inline rename mode owns the keyboard — ⏎ commit, esc cancel, ⌫
        // edit, printable types into the buffer. Every key is consumed so none
        // leaks to the filter/jump/create logic below.
        if switcherEditing {
            if kc == 36 { switcherCommitRename(); return true }            // ⏎
            if kc == 53 { switcherCancelRename(); return true }            // esc
            if kc == 51 {                                                  // ⌫
                if !switcherEditBuffer.isEmpty { switcherEditBuffer.removeLast(); renderSwitcher() }
                return true
            }
            if mods.subtracting(.shift).isEmpty,
               let chars = event.characters, chars.count == 1,
               let scalar = chars.unicodeScalars.first, BoardSwitcher.isTypable(scalar: scalar.value) {
                switcherEditBuffer += chars
                renderSwitcher()
                return true
            }
            // Swallow other un-modified keys; let ⌘-shortcuts (⌘Q) reach the menu.
            return !mods.contains(.command)
        }
        // P5.4: while a delete confirm is armed, esc cancels it (only); any key
        // other than the confirming ⌘⌫ disarms it and then acts normally.
        if switcherConfirmingDelete {
            if kc == 53 {
                switcherConfirmingDelete = false
                renderSwitcher()
                return true
            }
            if !(kc == 51 && mods == .command) {
                switcherConfirmingDelete = false
                renderSwitcher()
                // fall through: the key still performs its normal action
            }
        }
        if kc == 53 { closeSwitcher(); return true }                       // esc
        if kc == 40, mods == .command { closeSwitcher(); return true }     // ⌘K toggles closed
        if kc == 14, mods == .command { switcherBeginRename(); return true }      // ⌘E rename
        if kc == 51, mods == .command { switcherDeleteOrConfirm(); return true }  // ⌘⌫ delete
        if kc == 36 { switcherCommitSelected(); return true }              // ⏎
        if kc == 126 { switcherMove(by: -1); return true }                 // ↑
        if kc == 125 { switcherMove(by: 1); return true }                  // ↓
        if kc == 51 { switcherBackspace(); return true }                   // ⌫
        // ⌘1..9 jump to the visible row at that ordinal.
        if mods == .command, let s = event.charactersIgnoringModifiers, let n = Int(s), (1...9).contains(n) {
            switcherJump(ordinal: n)
            return true
        }
        // ⌘N creates a board. (Bare "n" would shadow the prefix filter for every
        // board whose name starts with "n", so create is ⌘N only; the footer says
        // so. All printable keys — including "n" — flow to the filter below.)
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "n" {
            switcherCreate()
            return true
        }
        // Printable typing → prefix filter.
        if mods.subtracting(.shift).isEmpty,
           let chars = event.characters, chars.count == 1,
           let scalar = chars.unicodeScalars.first, BoardSwitcher.isTypable(scalar: scalar.value) {
            switcherType(chars)
            return true
        }
        // Let other ⌘-shortcuts (⌘Q / ⌘W / …) reach the menu; swallow the rest so
        // the board stays inert.
        return !mods.contains(.command)
    }

    private func switcherMove(by delta: Int) {
        switcherSelected = BoardSwitcher.clampSelection(switcherSelected + delta, count: switcherRows.count)
        renderSwitcher()
    }

    private func switcherType(_ s: String) {
        switcherFilter += s
        rebuildSwitcherRows()
        renderSwitcher()
    }

    private func switcherBackspace() {
        guard !switcherFilter.isEmpty else { return }
        switcherFilter.removeLast()
        rebuildSwitcherRows()
        renderSwitcher()
    }

    private func switcherCommitSelected() {
        guard switcherRows.indices.contains(switcherSelected) else { closeSwitcher(); return }
        switchOrClose(to: switcherRows[switcherSelected].row.boardID)
    }

    private func switcherJump(ordinal n: Int) {
        guard let id = BoardSwitcher.boardID(forOrdinal: n, in: switcherRows.map(\.row)) else { return }
        switchOrClose(to: id)
    }

    /// A row was clicked.
    func switcherPickRow(_ index: Int) {
        guard switcherRows.indices.contains(index) else { return }
        switchOrClose(to: switcherRows[index].row.boardID)
    }

    private func switcherCreate() {
        closeSwitcher(restoreFocus: false)
        // The daemon mints `board-N`, auto-activates it, and pushes board_list +
        // restore; the daemon-initiated-switch path (handle(.boardList)) follows.
        client.boardCreate()
    }

    /// P5.4: enter inline rename mode for the selected board, seeding the edit
    /// buffer from its current display label.
    private func switcherBeginRename() {
        guard switcherRows.indices.contains(switcherSelected) else { return }
        switcherConfirmingDelete = false
        switcherEditing = true
        switcherEditBuffer = switcherRows[switcherSelected].row.display
        renderSwitcher()
    }

    /// P5.4: commit the rename (empty ⇒ clear to the slug) and leave edit mode.
    /// The daemon re-pushes board_list with the new name; the boardList handler
    /// rebuilds the rows.
    private func switcherCommitRename() {
        switcherEditing = false
        if switcherRows.indices.contains(switcherSelected) {
            let id = switcherRows[switcherSelected].row.boardID
            client.boardRename(boardID: id, name: BoardSwitcher.sanitizedName(switcherEditBuffer))
        }
        renderSwitcher()
    }

    /// P5.4: leave rename mode without committing.
    private func switcherCancelRename() {
        switcherEditing = false
        renderSwitcher()
    }

    /// P5.4: ⌘⌫ — arm the one-key delete confirm, or (when already armed) perform
    /// the delete. Refused for the last board (the daemon is authoritative; this
    /// mirror keeps the confirm banner from ever appearing). The daemon kills the
    /// board's ptys, fixes the active board if needed, and re-pushes board_list +
    /// restore; the boardList handler reconciles local boards + rebuilds the rows.
    private func switcherDeleteOrConfirm() {
        guard switcherRows.indices.contains(switcherSelected),
              BoardSwitcher.canDelete(boardCount: max(boardMetas.count, boards.count)) else {
            NSSound.beep()
            return
        }
        if !switcherConfirmingDelete {
            switcherConfirmingDelete = true
            renderSwitcher()
            return
        }
        switcherConfirmingDelete = false
        let id = switcherRows[switcherSelected].row.boardID
        client.boardDelete(boardID: id)
        // Close the switcher so a delete-of-active board's arriving switch isn't
        // fighting the open overlay; keep focus only for a non-active delete (an
        // active delete's arrive re-establishes focus on the new board).
        closeSwitcher(restoreFocus: id != activeBoardID)
    }

    /// Opening the selected/clicked/ordinal board: a no-op target (already active)
    /// just closes; otherwise close (without stealing focus) and switch.
    private func switchOrClose(to id: String) {
        if id == activeBoardID { closeSwitcher(); return }
        closeSwitcher(restoreFocus: false)
        performSwitch(to: id)
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
        switching = true
        // Keep prime synced to the terminal the user last typed in, then pull
        // first responder OFF the leaving board's views before the view is
        // swapped — a stale responder would leave the arrived board unfocused
        // (boardHasFocus false until a click). Target nil, not rootView.board,
        // which is about to be swapped (crit B3).
        reconcilePrimeToFocus()
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
        if let view = board.primeTerminalView {
            window?.makeFirstResponder(view)
        } else {
            window?.makeFirstResponder(rootView.board)
        }
        updatePrimacy()
        switching = false
        // Defensive: if an arrive ever lands while the ⌘K switcher is open, keep
        // the switcher as first responder so the veiled board can't steal the
        // keyboard.
        if switcherOpen { window?.makeFirstResponder(rootView.boardSwitcher) }
    }
}
