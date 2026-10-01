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
            connected = true
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
            refreshSwitcherIfOpen()
        case .restore(let docs, let tiles, let board, let restoredBoardID, let liveTerms):
            applyRestore(docs: docs, tiles: tiles, viewport: board, boardID: restoredBoardID, liveTerms: liveTerms)
        case .output(let termID, let bytes):
            // Shown whatever board the terminal is on: a backgrounded board's
            // shell keeps progressing and is current on switch-back.
            scrollback.output(termID, bytes)
        case .scrollback(let termID, let bytes):
            scrollback.reply(termID, bytes)
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
        terminalsLostConnection()
        rootView.toasts.show(title: "tarmacd connection lost", body: reason)
        // Every board's glyph goes faint (no live pty); refresh an open switcher.
        refreshSwitcherIfOpen()
    }
}
