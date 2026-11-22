import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Restore

    /// Applies a daemon `restore` to the board it is stamped for (`board_id`
    /// absent ⇒ board-0, legacy). A board's first restore builds it. Every later
    /// one — a switch back, or a reconnect — only reconciles its terminals
    /// against `live_terms`.
    ///
    /// The daemon sends a restore only for its active board, after the
    /// `board_list` that sets `activeBoardID`, so a restore for another board
    /// is stale: it arrived after a later switch. Such a board is not built or
    /// shown, but if it is already built it is still reconciled, because the
    /// daemon replays its terminals' history either way.
    func applyRestore(
        docs: [RestoreDoc], tiles: [LayoutTile], viewport: BoardViewport?, boardID: String?, liveTerms: [String],
        termRecords: [String: TermRecord]
    ) {
        let targetID = boardID ?? Board.defaultID
        guard let board = boards[targetID] else { return }
        let firstOnConnection = daemonSession.restoredBoards.insert(targetID).inserted
        let firstVisit = !board.didInitialRestore
        // Kept on every restore (2611.0011, D11): what a dead card offers.
        board.termRecords = termRecords
        guard targetID == activeBoardID else {
            if !firstVisit {
                reconcile(board, liveTerms: Set(liveTerms), replayFollows: firstOnConnection)
                spawnPending(on: board)
            }
            return
        }
        if switching { mount(board) }
        var card: RestoreCard?
        if firstVisit {
            board.didInitialRestore = true
            board.store.applyRestore(docs)
            card = build(
                board, tiles: tiles, docs: docs, viewport: viewport, liveTerms: Set(liveTerms), termRecords: termRecords
            )
        } else {
            reconcile(board, liveTerms: Set(liveTerms), replayFollows: firstOnConnection)
        }
        syncGrids(on: board)
        spawnPending(on: board)
        refreshChrome()
        sampleLog.restored()
        if switching {
            finishArrive(on: board)
        } else if firstVisit {
            // An open switcher keeps the keys and hands them on when it closes.
            if switcherOpen {
                rootView.boardSwitcher.keysOwner = board.primeTerminalView ?? rootView.board
            } else {
                focusPrimeTerminal()
            }
        }
        if let card { showRestoreCard(card) }
    }

    /// #358: the card over the board until a choice, any key or a click closes it.
    private func showRestoreCard(_ card: RestoreCard) {
        restoreCard = card
        rootView.setRestoreCard(card)
        rootView.layoutSubtreeIfNeeded()
        rootView.restoreCard.takeKeys()
    }

    /// 2611.0015 D1, D4, D5: `resume all` requests each offer of the board,
    /// which runs now or at its card's first output; `skip all` skips each;
    /// `decide per card` leaves them. Then the card closes.
    func chooseOnRestoreCard(_ action: RestoreCard.Choice.Action) {
        let event: ResumeOffer.Event? =
            switch action {
            case .resumeAll: .request
            case .skipAll: .skip
            case .perCard: nil
            }
        if let event {
            for termID in activeBoard.sessionOrder {
                guard let s = activeBoard.sessions[termID], s.resumeOffer != nil else { continue }
                stepResume(s, event)
            }
        }
        closeRestoreCard()
    }

    func closeRestoreCard() {
        restoreCard = nil
        // Before the view is hidden: hiding the first responder hands the keys
        // to the window, and there would be nothing left to give back.
        rootView.restoreCard.returnKeys(fallback: activeBoard.primeTerminalView ?? rootView.board)
        rootView.setRestoreCard(nil)
    }

    /// First visit: the board's cards are exactly what `BoardRestore.plan` says.
    /// The placeholder terminal the board showed until now never spawned, so
    /// dropping it orphans nothing. Returns the restore card the plan gives.
    private func build(
        _ board: Board, tiles: [LayoutTile], docs: [RestoreDoc], viewport: BoardViewport?, liveTerms: Set<String>,
        termRecords: [String: TermRecord]
    ) -> RestoreCard? {
        for termID in board.sessionOrder {
            scrollback.unmount(termID)
            termIndex.remove(termID: termID)
        }
        board.sessions = [:]
        board.sessionOrder = []
        for id in Array(board.view.cards.keys) {
            board.view.removeCard(id: id)
        }
        dataFiles.forget(board: board.boardID)

        let plan = BoardRestore.plan(
            tiles: tiles, docs: docs, liveTerms: liveTerms, termRecords: termRecords, mint: BootTerminal.mint
        )
        notifyRestored(tiles: tiles, liveTerms: liveTerms)
        for term in plan.terms {
            let s = addTerminal(
                term.termID, frame: CardFrame(rect: term.frame, z: term.z), spawn: term.spawn, resume: term.resume,
                on: board
            )
            s.lastCwd = termRecords[term.termID]?.lastCwd ?? term.spawn?.cwd
            setRecordedResume(s, RecordedResume.command(for: term, termRecords: termRecords), on: board)
        }
        board.primeTermID = plan.terms.first?.termID
        // Before `finishArrive` takes a pending jump: an exit row of a
        // terminal cold-spawned anew lands on the shell that succeeds it.
        let successors = plan.terms.compactMap { term in term.spawn?.succeeds.map { ($0, term.termID) } }
        let built = inbox.boardBuilt(
            boardID: board.boardID, cards: Set(plan.terms.map(\.termID)),
            successors: Dictionary(successors, uniquingKeysWith: { first, _ in first })
        )
        if built { inboxChanged() }

        board.docOwner = [:]
        for doc in docs {
            board.docOwner[doc.path] = doc.termID
        }
        for doc in plan.docs {
            board.docOwner[doc.path] = doc.ownerTermID
            landDocCard(
                path: doc.path, frame: CardFrame(rect: doc.frame, z: doc.z), attached: doc.attached, fresh: false,
                sidebar: doc.sidebar, on: board
            )
        }
        for path in plan.droppedDocPaths {
            Log.stderr("restore: doc tile \(path) absent from the registry — dropping")
        }

        board.view.setViewport(viewport ?? .default)
        updatePrimacy(on: board)
        // The ids minted for cold spawns are not on disk yet, and a relaunch
        // can only re-bind a shell whose id its tile carries.
        persistLayout(for: board)
        return RestoreCard.make(plan: plan)
    }

    /// The toast for terminals that a daemon replaced on a version mismatch
    /// took with it (`RestartNotice`), once per connection. What was restored
    /// is the restore card's (#358), not the toast's.
    private func notifyRestored(tiles: [LayoutTile], liveTerms: Set<String>) {
        guard
            let notice = RestartNotice.make(
                replaced: client.daemonReplaced,
                tileTermIDs: LayoutTiles.parse(tiles).terms.map(\.termID),
                liveTerms: liveTerms,
                alreadyNotified: daemonSession.restartNotified
            )
        else { return }
        daemonSession.restartNotified = true
        rootView.toasts.show(title: notice.title, bodyLines: [notice.body])
    }

    /// A restore for a board that is already built (`ReconnectRestore`):
    /// terminals the daemon still owns stay as they are, the rest become dead
    /// cards, and nothing is respawned. A daemon restart is announced once and
    /// takes every other board's terminals with it, since only the active board
    /// is sent a restore.
    private func reconcile(_ board: Board, liveTerms: Set<String>, replayFollows: Bool) {
        for (termID, s) in board.sessions {
            if let cwd = board.termRecords[termID]?.lastCwd { s.lastCwd = cwd }
            // A restore corrects a stale value (2611.0015 D11).
            if s.live {
                setRecordedResume(s, ResumeCommand.accepted(board.termRecords[termID]?.resume?.cmd), on: board)
            }
        }
        let outcome = ReconnectRestore.reconcile(
            board.reconnectTerms, liveTerms: liveTerms, replayFollows: replayFollows)
        markLost(outcome.lost, on: board)
        let offered = offerReopens(on: board)
        if outcome.daemonRestarted, !daemonSession.restartNotified {
            daemonSession.restartNotified = true
            let reopenable = outcome.lost.filter(offered.contains).count
            rootView.toasts.show(
                title: ReconnectRestore.restartToastTitle,
                bodyLines: [ReconnectRestore.restartToastBody(reopenable: reopenable)]
            )
        }
        if outcome.daemonRestarted {
            for other in boards.values where other !== board {
                markLost(ReconnectRestore.lostToRestart(other.reconnectTerms), on: other)
            }
        }
        // The daemon is about to send these terminals' rings again; holding its
        // output until the ring arrives lets the ring replace what they show.
        for termID in outcome.replayed {
            scrollback.mount(termID)
        }
        refreshSwitcherIfOpen()
    }

    private func markLost(_ termIDs: [String], on board: Board) {
        guard !termIDs.isEmpty else { return }
        for termID in termIDs {
            guard let s = board.sessions[termID] else { continue }
            holdOpen(s, on: board)
        }
        // A lost terminal sends no `exit`, so its report ends here.
        let ended = Set(termIDs.filter { inbox.reportEnded(termID: $0) })
        if !ended.isEmpty { inboxChanged(ended) }
        board.reassignPrime()
        updatePrimacy(on: board)
        persistLayout(for: board)
    }

    // MARK: - Persistence

    /// A board changed: its layout snapshot goes out once it has been still for
    /// the debounce. The board need not be the active one.
    func persistLayout(for board: Board) {
        layoutPersister.schedule(board.boardID)
    }

    /// Sends every snapshot still owed, now — on a board switch, when the app
    /// resigns active, and at quit.
    func flushPendingPersist() {
        layoutPersister.flush()
    }

    /// The `layout` message for `boardID` (docs/protocol.md; last writer wins),
    /// stamped with its `board_id` so the daemon files it under that board
    /// whatever it considers active. A board is never persisted before its
    /// first restore: until then it holds a placeholder, and the snapshot would
    /// overwrite the layout the restore is about to deliver.
    func sendLayout(boardID: String) {
        guard let board = boards[boardID], board.didInitialRestore else { return }
        let terms = board.sessionOrder.compactMap { termID -> LayoutTiles.TermInput? in
            guard let card = board.view.card(.term(termID)) else { return nil }
            return LayoutTiles.TermInput(
                termID: termID, frame: card.worldFrame.rect, z: Double(card.worldFrame.z), dead: card.dead
            )
        }
        let docs = board.boardDocPaths.compactMap { path -> LayoutTiles.DocInput? in
            guard let card = board.view.card(.doc(path)) else { return nil }
            return LayoutTiles.DocInput(
                path: path, frame: card.worldFrame.rect, z: Double(card.worldFrame.z), attached: card.attached,
                sidebar: card.docSidebar
            )
        }
        client.layout(
            dock: board.store.docs.map(\.path),
            tiles: LayoutTiles.build(terms: terms, docs: docs),
            board: board.view.viewport,
            boardID: board.boardID
        )
    }
}
