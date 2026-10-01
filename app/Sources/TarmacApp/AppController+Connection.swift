import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Daemon link

    /// The version is the daemon's own string or nothing (`AppVersion`): a
    /// guessed one would make every launch replace the daemon.
    static func daemonClient() -> DaemonClient {
        DaemonClient(appVersion: AppVersion.resolve(
            bundleShortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            env: ProcessInfo.processInfo.environment
        ))
    }

    /// Handlers first, then the connection: the daemon's `board_list` and
    /// `restore` follow its `hello_ok` at once, and must find them installed.
    func connectToDaemon() {
        client.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        client.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.handle(status) }
        }
        client.start()
    }

    func handle(_ status: ConnectionStatus) {
        let dropped = connectionStatus.connected && !status.connected
        connectionStatus = status
        updateSessionLiveness()
        if dropped { handleDisconnect(status.reason) }
    }

    // MARK: - Daemon messages

    func handle(_ message: Message) {
        switch message {
        case .helloOK:
            // A reconnect is in flight iff boards are queued for revive (only
            // disconnect populates that). On a cold first connect the set is
            // empty, so the normal boot spawn runs; on a reconnect the imminent
            // board_list + restore drive the revive (and would orphan a surviving
            // shell if we cold-spawned the detached prime here), so skip maybeSpawn.
            let isReconnect = !boardsAwaitingRevive.isEmpty
            connected = true
            if !isReconnect { maybeSpawn() }
        case .boardList(let metas, let active):
            boardMetas = metas
            // P5.4: sync each visited board's local display name from the daemon's
            // authoritative list, so a rename reflects in the window title +
            // status bar (which read `activeBoard.name`), not just the switcher rows.
            for meta in metas { boards[meta.boardID]?.name = meta.name }
            // The daemon changed the active board out from under us (board_create
            // auto-activates the new board): follow it — leave the current board
            // so the restore that follows mounts the new one. An app-initiated
            // switch already set activeBoardID = active, so this is a no-op then.
            if active != activeBoardID, !switching {
                beginArrivingSwitch(to: active)
            }
            // P5.4: a board the daemon's list no longer carries (deleted here or by
            // another app) is dropped locally — its detached cards/sessions go and
            // routing to it stops. Never the active board: the daemon fixes active
            // before sending this, so `activeBoardID` always names a live board.
            let liveBoardIDs = Set(metas.map(\.boardID))
            for id in Array(boards.keys) where id != activeBoardID && !liveBoardIDs.contains(id) {
                removeBoard(id)
            }
            refreshStrips()
            // Keep an open switcher in sync with board adds/removes/active-change.
            if switcherOpen {
                rebuildSwitcherRows()
                renderSwitcher()
            }
        case .restore(let docs, let tiles, let board, let restoredBoardID, let liveTerms):
            applyRestore(docs: docs, tiles: tiles, viewport: board, boardID: restoredBoardID, liveTerms: liveTerms)
        case .output(let termID, let bytes):
            // Route to the owning board's session (which may be backgrounded):
            // feeding a detached terminal view still advances its buffer, so a
            // background board's shell keeps progressing and shows fresh output
            // on switch-back. Never touches the active view unless it owns the term.
            guard let s = session(ofTerm: termID), s.live else { return }
            s.view.feed(bytes)
        case .exit(let termID, let code):
            handleExit(termID: termID, code: code)
        case .docOpened(let doc):
            handleDocOpened(doc)
        case .fileEvent(let path, let mtimeMs):
            // The watcher is global; route the event to every board whose store
            // knows the path (a doc can live on a backgrounded board). Only the
            // active board's card re-renders.
            for board in boards.values where board.store.doc(for: path) != nil {
                board.store.applyFileEvent(path: path, mtimeMs: mtimeMs)
            }
            if isOnBoard(path) {
                activeBoard.view.card(.doc(path))?.renderDoc(markdown: readMarkdown(path))
            }
        case .termProc(let termID, let name, _):
            handleTermProc(termID: termID, name: name)
        case .bell(let termID):
            handleBell(termID: termID)
        default:
            break
        }
    }

    /// The link went from connected to not. The client reconnects by itself;
    /// this is only what the board owes the user meanwhile.
    private func handleDisconnect(_ reason: String?) {
        connected = false
        // The connection dropped for every board's ptys, not just the active one.
        // P5.3: DETACH (not kill) each live session — the shell may still be alive
        // daemon-side, to be re-bound on reconnect. Queue every board that had a
        // live session for revive (so its next restore re-binds survivors / cold-
        // spawns the gone ones, and `maybeSpawn` stays gated off its detached prime).
        for board in boards.values {
            var hadLive = false
            for s in board.sessions.values where s.live {
                s.live = false
                hadLive = true
            }
            if hadLive { boardsAwaitingRevive.insert(board.boardID) }
        }
        activeBoard.view.signalsChanged()
        rootView.toasts.show(title: "tarmacd connection lost", body: reason)
        // Every board's glyph goes faint (no live pty); refresh an open switcher.
        refreshSwitcherIfOpen()
    }
}
