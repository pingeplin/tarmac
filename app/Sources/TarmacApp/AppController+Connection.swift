import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Daemon messages

    func handle(_ message: Message) {
        switch message {
        case .helloOK:
            connected = true
            reconnecting = false
            reconnectAttempt = 0
            updateSessionLiveness()
            maybeSpawn()
        case .boardList(let metas, let active):
            boardMetas = metas
            // P5.4: sync each visited board's local display name from the daemon's
            // authoritative list, so a rename reflects in the titlebar chip +
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
        case .err(let msg):
            FileHandle.standardError.write(Data("tarmacd err: \(msg)\n".utf8))
        case .unknown(let type):
            FileHandle.standardError.write(Data("tarmac: ignoring unknown message type \"\(type)\"\n".utf8))
        default:
            break
        }
    }

    func handleDisconnect(_ reason: String) {
        connected = false
        // The connect() attempt this drop corresponds to is over — clear the latch
        // so scheduleReconnect can re-arm. Without this, a drop in the handshake
        // window (connect() returned, but the link died before hello_ok cleared
        // `reconnecting`) would wedge the loop forever (scheduleReconnect's
        // !reconnecting guard would never pass again). Idempotent on the normal
        // path (hello_ok already cleared it before any later real drop).
        reconnecting = false
        terminalsLostConnection()
        feedNotice("lost connection to tarmacd — \(reason)")
        rootView.toasts.show(title: "tarmacd connection lost", body: reason)
        // P5: the chip + status word flip to detached (faint) immediately.
        updateSessionLiveness()
        // Every board's glyph goes faint (no live pty); refresh an open switcher.
        refreshSwitcherIfOpen()
        // P5.3: schedule a bounded auto-reconnect. The same DaemonClient instance
        // reconnects (connectOnce re-sets closed=false); on success hello_ok + the
        // daemon's board_list/restore revive the still-live terms.
        scheduleReconnect()
    }

    func showConnectFailure(_ detail: String) {
        feedNotice(detail)
        rootView.toasts.show(title: "cannot reach tarmacd", body: "see terminal for details")
    }

    /// P5.3: schedule the next bounded reconnect attempt. No-op when quitting,
    /// already connected (a race where hello_ok beat us), or a connect is already
    /// in flight. The per-attempt delay + the give-up bound come from `Reconnect`;
    /// exhausting the budget surfaces a terminal notice and stops.
    private func scheduleReconnect() {
        guard !quitting, !connected, !reconnecting else { return }
        reconnectAttempt += 1
        guard let delay = Reconnect.delay(forAttempt: reconnectAttempt) else {
            feedNotice("could not reconnect to tarmacd — relaunch to retry")
            rootView.toasts.show(title: "tarmacd unreachable", body: "reconnect attempts exhausted")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptReconnect()
        }
    }

    /// P5.3: run one reconnect attempt on a background queue (mirrors `start`'s
    /// connect block). On failure, re-arm the next bounded attempt; on success the
    /// `reconnecting` latch is cleared in `hello_ok` (the real attached signal),
    /// and the daemon's board_list + restore drive the revive. `connect()` is
    /// blocking (incl. up to ~3 s of TARMAC_DAEMON spawn retries), so the
    /// `reconnecting` guard prevents a backoff timer from launching a second one.
    private func attemptReconnect() {
        guard !quitting, !connected, !reconnecting else { return }
        reconnecting = true
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try client.connect()
                // Success: hello_ok (delivered via onMessage) clears `reconnecting`
                // + reconnectAttempt and drives the revive.
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        guard let self else { return }
                        self.reconnecting = false
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }
}
