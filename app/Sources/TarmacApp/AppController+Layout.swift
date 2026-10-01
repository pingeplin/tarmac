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
    func applyRestore(docs: [RestoreDoc], tiles: [LayoutTile], viewport: BoardViewport?, boardID: String?, liveTerms: [String]) {
        let targetID = boardID ?? Board.defaultID
        guard let board = boards[targetID] else { return }
        let firstOnConnection = daemonSession.restoredBoards.insert(targetID).inserted
        let firstVisit = !board.didInitialRestore
        guard targetID == activeBoardID else {
            if !firstVisit {
                reconcile(board, liveTerms: Set(liveTerms), replayFollows: firstOnConnection)
                spawnPending(on: board)
            }
            return
        }
        if switching { mount(board) }
        if firstVisit {
            board.didInitialRestore = true
            board.store.applyRestore(docs)
            build(board, tiles: tiles, docs: docs, viewport: viewport, liveTerms: Set(liveTerms))
        } else {
            reconcile(board, liveTerms: Set(liveTerms), replayFollows: firstOnConnection)
        }
        syncGrids(on: board)
        spawnPending(on: board)
        refreshStrips()
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
    }

    /// First visit: the board's cards are exactly what `BoardRestore.plan` says.
    /// The placeholder terminal the board showed until now never spawned, so
    /// dropping it orphans nothing.
    private func build(
        _ board: Board, tiles: [LayoutTile], docs: [RestoreDoc], viewport: BoardViewport?, liveTerms: Set<String>
    ) {
        for termID in board.sessionOrder {
            scrollback.unmount(termID)
            termIndex.remove(termID: termID)
        }
        board.sessions = [:]
        board.sessionOrder = []
        for id in Array(board.view.cards.keys) {
            board.view.removeCard(id: id)
        }

        notifyDaemonReplaced(tiles: tiles, liveTerms: liveTerms)
        let plan = BoardRestore.plan(tiles: tiles, docs: docs, liveTerms: liveTerms, mint: BootTerminal.mint)
        for term in plan.terms {
            addTerminal(
                term.termID, frame: CardFrame(rect: term.frame, z: term.z), needsSpawn: term.needsSpawn, on: board
            )
        }
        board.primeTermID = plan.terms.first?.termID

        board.docOwner = [:]
        for doc in docs {
            board.docOwner[doc.path] = doc.termID
        }
        for doc in plan.docs {
            board.docOwner[doc.path] = doc.ownerTermID
            landDocCard(
                path: doc.path, frame: CardFrame(rect: doc.frame, z: doc.z), attached: doc.attached, fresh: false,
                on: board
            )
        }
        for path in plan.droppedDocPaths {
            let log = "tarmac: restore: doc tile \(path) absent from the registry — dropping\n"
            FileHandle.standardError.write(Data(log.utf8))
        }

        board.view.setViewport(viewport.map(Viewport.init) ?? .default)
        updatePrimacy(on: board)
        // The ids minted for cold spawns are not on disk yet, and a relaunch
        // can only re-bind a shell whose id its tile carries.
        persistLayout(for: board)
    }

    /// The toast for terminals that a daemon replaced on a version mismatch
    /// took with it (`RestartNotice`); once per connection.
    private func notifyDaemonReplaced(tiles: [LayoutTile], liveTerms: Set<String>) {
        guard let notice = RestartNotice.make(
            replaced: client.daemonReplaced,
            tileTermIDs: LayoutTiles.parse(tiles).terms.map(\.termID),
            liveTerms: liveTerms,
            alreadyNotified: daemonSession.restartNotified
        ) else { return }
        daemonSession.restartNotified = true
        rootView.toasts.show(title: notice.title, body: notice.body)
    }

    /// A restore for a board that is already built (`ReconnectRestore`):
    /// terminals the daemon still owns stay as they are, the rest become dead
    /// cards, and nothing is respawned. A daemon restart is announced once and
    /// takes every other board's terminals with it, since only the active board
    /// is sent a restore.
    private func reconcile(_ board: Board, liveTerms: Set<String>, replayFollows: Bool) {
        let outcome = ReconnectRestore.reconcile(board.reconnectTerms, liveTerms: liveTerms, replayFollows: replayFollows)
        if outcome.daemonRestarted, !daemonSession.restartNotified {
            daemonSession.restartNotified = true
            rootView.toasts.show(
                title: ReconnectRestore.restartToastTitle, body: ReconnectRestore.restartToastBody
            )
        }
        markLost(outcome.lost, on: board)
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
        board.reassignPrime()
        updatePrimacy(on: board)
        persistLayout(for: board)
    }

    // MARK: - Persistence

    /// A board changed: its layout snapshot goes out once it has been still for
    /// the debounce. The board need not be the active one.
    func persistLayout(for board: Board) {
        schedulePersist(boardID: board.boardID)
    }

    func persistLayout() {
        persistLayout(for: activeBoard)
    }

    func schedulePersist(boardID: String) {
        layoutPersister.schedule(boardID)
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
                path: path, frame: card.worldFrame.rect, z: Double(card.worldFrame.z), attached: card.attached
            )
        }
        client.layout(
            dock: board.store.docs.map(\.path),
            tiles: LayoutTiles.build(terms: terms, docs: docs),
            board: board.view.viewport.wire,
            boardID: board.boardID
        )
    }
}
