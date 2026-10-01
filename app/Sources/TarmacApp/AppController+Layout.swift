import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Board layout (restore + persistence)

    /// Applies a daemon `restore` to the board it is stamped for. The daemon
    /// sends a restore only for its active board, and the `board_list` that sets
    /// `activeBoardID` always precedes it, so the restore's `board_id` matches
    /// the active board; a restore for any other board is stale (it arrived after
    /// a later switch) and is dropped (restore-ordering guard). A board that has
    /// already taken its first restore is not rebuilt — that would tear down its
    /// doc cards and respawn its live terminals; the switch path re-mounts the
    /// existing view instead (Step 9). `board_id` absent ⇒ board-0 (legacy).
    func applyRestore(docs: [RestoreDoc], tiles: [LayoutTile], viewport: BoardViewport?, boardID: String?, liveTerms: [String]) {
        let targetID = boardID ?? Board.defaultID
        guard targetID == activeBoardID, let board = boards[targetID] else { return }
        // On a switch-arrive, mount the target's view (boot already mounted
        // board-0). A re-visit still mounts + refocuses below — only the rebuild
        // is gated on the first restore.
        if switching { mount(board) }
        // P5.3: a reconnect restore for an already-restored board re-binds its
        // detached terminals — survivors (term_id ∈ liveTerms) rebind in place +
        // consume the replayed scrollback; the gone ones cold-spawn (daemon
        // restarted / shell exited while detached). Runs before the first-restore
        // block, which it does not reach (didInitialRestore is already true here).
        if board.didInitialRestore, boardsAwaitingRevive.contains(targetID) {
            boardsAwaitingRevive.remove(targetID)
            reviveTerminals(on: board, liveTerms: Set(liveTerms))
        }
        // Build the board's cards/terminals on its FIRST restore only; a re-visit
        // keeps its live view as-is (a rebuild would respawn its terminals).
        if !board.didInitialRestore {
            board.didInitialRestore = true
            board.store.applyRestore(docs)
            // Seed provenance from the restored doc entries (term_id owner).
            for doc in docs {
                if let termID = doc.termID { board.docOwner[doc.path] = termID }
            }
            applyRestoredLayout(tiles: tiles, board: viewport, liveTerms: Set(liveTerms))
            // Boot-spawn triggers (helloOK / initial viewReady) fire once per
            // launch; a switch-arrival must drive the arriving board's prime
            // spawn itself (crit S1). Lay the just-mounted view out first so the
            // boot pty starts at the card size, not the 800×600 view default.
            // P5: `maybeSpawn` is now gated on `didInitialRestore` (just set), so
            // a cold prime spawns HERE — never before the restore decided whether
            // to re-bind it to a surviving shell instead.
            rootView.layoutSubtreeIfNeeded()
            maybeSpawn()
        }
        refreshStrips()
        if switching { finishArrive(on: board) }
    }

    /// `restore.tiles[]` → board cards. A geometry-bearing doc tile becomes a
    /// board card seeded from the doc's provenance owner (attached = !loose); a
    /// geometry-less doc tile is an M1 layout → default scatter migration,
    /// unless it is a legacy `shelf:true` tile, which is dropped. The terminal
    /// card always survives. Unknown kinds and unregistered doc paths are
    /// skipped (protocol receiver rules). The board viewport is applied when
    /// present, else the default.
    private func applyRestoredLayout(tiles: [LayoutTile], board: BoardViewport?, liveTerms: Set<String>) {
        // Tear down any doc cards from a prior restore; the term card is kept and
        // re-placed (its embedded terminal view stays attached). Snapshot the ids
        // first — removeCard mutates the board's `cards` dictionary.
        for id in Array(activeBoard.view.cards.keys) {
            if case .doc = id { activeBoard.view.removeCard(id: id) }
        }

        let termTiles = tiles.filter { $0.kind == "term" }
        let docTiles = tiles.filter { $0.kind == "doc" }
        var migratedAny = termTiles.contains { CardFrame(tile: $0) == nil }

        // Restore N terminal cards: re-bind a card to its surviving daemon pty
        // (P5) when the daemon reports it live, else cold-spawn (positions persist,
        // fresh shell). Re-anchor doc provenance across the restart (best-effort).
        let oldToNew = restoreTerminals(termTiles, liveTerms: liveTerms)
        remapDocOwners(oldToNew, restoredTerminalCount: termTiles.count)

        var docSlot = 0
        for tile in docTiles {
            guard let path = tile.path, store.doc(for: path) != nil, tile.shelf != true else { continue }
            if let stored = CardFrame(tile: tile) {
                landDocCard(path: path, frame: stored, attached: tile.loose != true, fresh: false)
            } else {
                // Geometry-less doc tile: M1 migration → scatter.
                migratedAny = true
                landDocCard(path: path, frame: scatterFrame(docSlot: docSlot), attached: tile.loose != true, fresh: false)
            }
            docSlot += 1
        }

        if migratedAny {
            let origin = "\(Int(Place.termFrame.x)),\(Int(Place.termFrame.y))"
            let docSize = "\(Int(Place.docW))×\(Int(Place.docH))"
            let log = "tarmac: migrated M1 layout → default scatter "
                + "(term near origin at \(origin); doc cards \(docSize) in a "
                + "\(Place.docColumns)-col grid right of the terminal)\n"
            FileHandle.standardError.write(Data(log.utf8))
        }

        activeBoard.view.setViewport(board.map(Viewport.init) ?? .default)
    }

    /// Restores terminal cards from `termTiles`. P5: a tile whose persisted
    /// `term_id` is among the daemon's `liveTerms` RE-BINDS to that still-running
    /// pty (no spawn — the replayed scrollback that follows the restore repaints
    /// it); every other tile cold-spawns a fresh shell at the persisted position
    /// (a shell that exited while detached, or a daemon that restarted). The first
    /// tile is the prime/boot terminal. Returns the persisted→reborn `term_id`
    /// remap (identity for a re-bound term) so doc provenance can re-anchor.
    @discardableResult
    private func restoreTerminals(_ termTiles: [LayoutTile], liveTerms: Set<String>) -> [String: String] {
        var oldToNew: [String: String] = [:]
        guard let bootID = primeTermID else { return oldToNew }
        let plans = TermRestore.plan(tileTermIDs: termTiles.map(\.termID), liveTerms: liveTerms)
        for (i, tile) in termTiles.enumerated() {
            let frame = CardFrame(tile: tile) ?? Place.termFrame
            let newID: String
            switch (i, plans[i]) {
            case (_, .rebind(let liveID)) where i == 0:
                // Re-bind the prime to a surviving shell: discard the empty,
                // never-spawned boot session and bind a live one under the
                // daemon's id (maybeSpawn is gated until now, so the boot pty was
                // never spawned — nothing to orphan).
                adoptPrimeForRebind(liveID: liveID, frame: frame)
                newID = liveID
            case (_, .rebind(let liveID)):
                // Re-bind an additional terminal: a live, no-spawn session.
                bindLiveTerminal(termID: liveID, frame: frame)
                newID = liveID
            case (0, .coldSpawn):
                // Cold prime: reuse the pre-minted boot session/card; its fresh
                // shell is spawned by the post-restore `maybeSpawn`.
                newID = bootID
                if let view = primeTerminalView {
                    activeBoard.view.setTerminal(termID: bootID, view, worldFrame: frame)
                }
            case (_, .coldSpawn):
                // Cold extra terminal: a fresh session + card + pty.
                newID = BootTerminal.mint()
                let session = makeSession(termID: newID)
                sessions[newID] = session
                sessionOrder.append(newID)
                termIndex.assign(termID: newID, to: activeBoardID)
                activeBoard.view.setTerminal(termID: newID, session.view, worldFrame: frame)
                // Lay out before spawn so the pty starts at the restored card
                // size, not the 800×600 view default.
                rootView.layoutSubtreeIfNeeded()
                spawn(session: session)
            }
            if let old = tile.termID { oldToNew[old] = newID }
        }
        return oldToNew
    }

    /// P5: bind a card to a daemon-owned LIVE pty without spawning — the shell is
    /// already running; the replayed scrollback (delivered right after the
    /// restore) repaints it. The session is created `live` BEFORE replay arrives
    /// so the `.output` guard does not drop it. The honest foreground name will
    /// follow on the next `term_proc`; until then the card shows the shell name.
    private func bindLiveTerminal(termID: String, frame: CardFrame) {
        let session = makeSession(termID: termID)
        session.live = true
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shell = (shellPath as NSString).lastPathComponent
        session.label = shell
        session.shellName = shell
        sessions[termID] = session
        sessionOrder.append(termID)
        termIndex.assign(termID: termID, to: activeBoardID)
        activeBoard.view.setTerminal(termID: termID, session.view, worldFrame: frame)
        let card = activeBoard.view.card(.term(termID))
        card?.setTermLabel(shell)
        // The cyan foreground-busy signal is unknown until the next term_proc —
        // default idle (matches spawn); session.live (pty-alive) drives routing.
        card?.setLive(false)
    }

    /// P5: replace the pre-minted (empty, unspawned) boot session with a live one
    /// bound to the daemon's surviving prime shell `liveID`, then make it prime.
    /// Safe because `maybeSpawn` is gated on `didInitialRestore`, so the boot pty
    /// was never spawned — there is nothing to orphan.
    private func adoptPrimeForRebind(liveID: String, frame: CardFrame) {
        if let boot = primeTermID, boot != liveID {
            sessions[boot] = nil
            sessionOrder.removeAll { $0 == boot }
            termIndex.remove(termID: boot)
            activeBoard.view.removeCard(id: .term(boot))
        }
        bindLiveTerminal(termID: liveID, frame: frame)
        primeTermID = liveID
    }

    /// P5.3: re-bind a board's detached terminals after a reconnect, in place —
    /// keeping each card + its `term_id`, so doc cards and gravity are untouched
    /// (no full rebuild). Each detached (non-dead) session gets a FRESH empty
    /// terminal view swapped into its existing card (so the daemon's replayed
    /// scrollback repaints cleanly, never duplicating the pre-disconnect buffer);
    /// then it either revives (its shell survived — `term_id ∈ liveTerms`, no
    /// spawn) or cold-spawns a fresh shell under the same id (the shell is gone:
    /// the daemon restarted, or it exited while we were detached). Dead cards stay
    /// dead. The prime pointer is preserved across the swap.
    private func reviveTerminals(on board: Board, liveTerms: Set<String>) {
        let isActive = board === activeBoard
        for tid in board.sessionOrder {
            guard let card = board.view.card(.term(tid)), !card.dead else { continue }
            let frame = card.worldFrame
            // Swap in a fresh, empty session/view bound to the same id + card.
            let fresh = makeSession(termID: tid)
            board.sessions[tid] = fresh
            board.view.setTerminal(termID: tid, fresh.view, worldFrame: frame)
            // term_id → board ownership survived the disconnect (only exit clears
            // it), so routing is already correct for both branches.
            if liveTerms.contains(tid) {
                // Survivor: rebind, NO spawn — the replayed scrollback repaints the
                // fresh view; the honest foreground name follows on the next
                // term_proc, until then the card shows the shell basename.
                fresh.live = true
                let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let shell = (shellPath as NSString).lastPathComponent
                fresh.label = shell
                fresh.shellName = shell
                card.setTermLabel(shell)
                card.setLive(false)
            } else {
                // Gone: cold-spawn a fresh shell into the same card under the same
                // id (layout-only restore). Lay out first so the pty starts at the
                // card size, not the 800×600 view default.
                if isActive { rootView.layoutSubtreeIfNeeded() }
                spawn(session: fresh)
            }
        }
        updatePrimacy(on: board)
        board.view.signalsChanged()
        // Re-establish focus on the (now-live) prime when this is the board the
        // user is looking at.
        if isActive, let view = board.primeTerminalView {
            window?.makeFirstResponder(view)
        }
    }

    /// Re-anchors persisted doc provenance across a restart (decision 2,
    /// best-effort): rewrites each owner `term_id` to the reborn session via
    /// `oldToNew`. When exactly one terminal restored (the common single-terminal
    /// case), re-anchors every owner-bearing doc to it losslessly; otherwise a
    /// doc whose owning terminal genuinely vanished keeps its stale id and
    /// restores loose (`ownerCardID` won't resolve it).
    private func remapDocOwners(_ oldToNew: [String: String], restoredTerminalCount: Int) {
        let soleTerminal = restoredTerminalCount == 1 ? primeTermID : nil
        docOwner = Provenance.remappedOwners(docOwner, oldToNew: oldToNew, soleTerminal: soleTerminal)
    }

    /// Default scatter for a geometry-less (M1) doc tile at `docSlot` (0-based):
    /// doc cards flow left→right, top→bottom in a `docColumns`-wide grid placed
    /// to the right of the terminal card, gapX past its right edge.
    private func scatterFrame(docSlot: Int) -> CardFrame {
        let term = Place.termFrame
        let col = docSlot % Place.docColumns
        let row = docSlot / Place.docColumns
        let x = term.x + term.w + Place.gapX + CGFloat(col) * (Place.docW + Place.gapX)
        let y = term.y + CGFloat(row) * (Place.docH + Place.gapY)
        return CardFrame(x: x, y: y, w: Place.docW, h: Place.docH, z: docSlot + 1)
    }

    /// Reports the full layout snapshot (docs/protocol.md `layout`;
    /// last-writer-wins): each terminal card's frame + its `term_id` (Phase 5b:
    /// N terminal cards, live AND dead, persist distinct positions) and each board
    /// doc card's frame with its `loose` flag. Plus the board
    /// viewport `{zoom,cx,cy}`. Fired on every committed board
    /// move/resize/zoom/pan, and on card-set/gravity changes.
    func persistLayout() {
        persistLayout(for: activeBoard)
    }

    // MARK: Debounced pan/zoom persistence (fix #2)

    /// Coalesces an `onLayoutChanged` persist: remember the board, (re)arm a
    /// trailing timer. A burst of scroll events collapses to one snapshot+IPC once
    /// panning stops for `persistDebounceInterval`.
    func schedulePersist(boardID: String) {
        pendingPersistBoardID = boardID
        persistDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistDebounce = nil
            self.flushPendingPersist()
        }
        persistDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDebounceInterval, execute: work)
    }

    /// Flushes any pending debounced persist immediately — called on switch-away
    /// (while the leaving board is still active, so its guard passes), resign-active,
    /// and terminate, so a settling pan's last position is never lost.
    func flushPendingPersist() {
        persistDebounce?.cancel()
        persistDebounce = nil
        guard let bid = pendingPersistBoardID else { return }
        pendingPersistBoardID = nil
        persistLayout(forBoardID: bid)
    }

    /// Persists `boardID`'s layout (the form `onLayoutChanged` calls, since its
    /// closure captures the board's id by value).
    private func persistLayout(forBoardID boardID: String) {
        guard let board = boards[boardID] else { return }
        persistLayout(for: board)
    }

    /// Builds the full layout snapshot for `board` and sends it stamped with its
    /// `board_id`, so the daemon persists it to the right board regardless of
    /// what it considers active. Only the active board is persisted: a committed
    /// layout change can only originate from the mounted board (input + gestures
    /// reach no detached view), so a callback from a non-active board is a
    /// teardown transient and is dropped (the per-board correctness guard that
    /// replaces the P2 renderedBoardID suppression).
    func persistLayout(for board: Board) {
        // Drop everything during a switch transient (unmount / re-mount /
        // rebuild fire layout passes whose geometry is mid-flight) and any
        // callback from a non-active board (input/gestures reach no detached view).
        guard !switching, board === activeBoard else { return }
        var tiles: [LayoutTile] = []
        // Terminal cards in spawn order, EXCLUDING exited ones (hold-open
        // placeholders, whose card is `dead`) so they never reappear on relaunch
        // (2606.0001). A detached survivor (card not `dead`, but session !live)
        // is kept and re-binds on reconnect — so the partition keys off `dead`
        // (exited), NOT `session.live`. Routed through the unit-tested
        // `TermExit.persistedTermIDs`.
        let survivingTermIDs = TermExit.persistedTermIDs(
            board.sessionOrder.compactMap { tid in
                board.view.card(.term(tid)).map { (termID: tid, exited: $0.dead) }
            }
        )
        for tid in survivingTermIDs {
            guard let card = board.view.card(.term(tid)) else { continue }
            tiles.append(boardTile(kind: "term", path: nil, termID: tid, card: card))
        }
        for path in board.boardDocPaths.sorted() {
            guard let card = board.view.card(.doc(path)) else { continue }
            tiles.append(boardTile(kind: "doc", path: path, card: card))
        }
        client.layout(
            dock: store.docs.map(\.path),
            tiles: tiles,
            board: board.view.viewport.wire,
            boardID: board.boardID
        )
    }

    /// A board card → tile: its world frame, `loose` = !attached (doc tiles), and
    /// the owning `term_id` (terminal tiles, Phase 5b).
    private func boardTile(kind: String, path: String?, termID: String? = nil, card: CardView) -> LayoutTile {
        let f = card.worldFrame
        return LayoutTile(
            kind: kind,
            path: path,
            x: Double(f.x),
            y: Double(f.y),
            w: Double(f.w),
            h: Double(f.h),
            z: f.z,
            // The term card has no gravity tie; doc cards carry their attached
            // state as the loose flag.
            loose: kind == "doc" ? !card.attached : nil,
            termID: termID
        )
    }
}
