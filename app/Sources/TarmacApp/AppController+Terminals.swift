import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Terminal session

    /// Builds a terminal session whose view reports to this controller under its
    /// `term_id`. The view is not yet on the board or spawned. `onBell` stays
    /// unset: the daemon's `bell` is the observed fact, and a view-side bell would
    /// ring twice. `onClipboardWrite` stays unset so a program cannot overwrite
    /// the user's clipboard (OSC 52).
    func makeSession(termID: String) -> TerminalSession {
        let view: TerminalView
        do {
            view = try TerminalView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: .breeze, fontSize: Theme.termFontSize
            )
        } catch {
            fatalError("tarmac: could not create a terminal view: \(error)")
        }
        view.onInput = { [weak self] bytes in self?.terminalDidSend(termID: termID, Data(bytes)) }
        view.onResize = { [weak self] cols, rows in
            self?.terminalSizeChanged(termID: termID, cols: cols, rows: rows)
        }
        view.onTitleChanged = { [weak self] title in self?.handleTermTitle(termID: termID, title: title ?? "") }
        view.onActivity = { [weak self] in self?.terminalActivity(termID: termID) }
        view.onOpenLink = { link in
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            NSWorkspace.shared.open(url)
        }
        view.keyOverride = { chord in
            TermKeyBinding.bytes(
                keyCode: chord.keyCode, modifierFlags: Self.modifierFlags(chord.mods), composing: chord.isComposing
            )
        }
        return TerminalSession(termID: termID, view: view)
    }

    /// The raw `NSEvent.ModifierFlags` bits `TermKeyBinding` matches on, rebuilt
    /// from a terminal key chord's intent modifiers.
    private static func modifierFlags(_ mods: KeyMods) -> UInt {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.shift) { flags.insert(.shift) }
        if mods.contains(.control) { flags.insert(.control) }
        if mods.contains(.option) { flags.insert(.option) }
        if mods.contains(.command) { flags.insert(.command) }
        return flags.rawValue
    }

    /// A terminal view reported new cols/rows or bytes for its pty. Either can
    /// come from a backgrounded board — a program there still asks the terminal
    /// about itself (DA1, cursor position) and blocks on the answer — so the
    /// session is looked up on its owning board, not the active one.
    func terminalSizeChanged(termID: String, cols: Int, rows: Int) {
        viewReady = true
        maybeSpawn()
        guard let s = session(ofTerm: termID), s.live, cols > 0, rows > 0,
              cols != s.lastSentCols || rows != s.lastSentRows else { return }
        s.lastSentCols = cols
        s.lastSentRows = rows
        client.resize(termID: termID, cols: cols, rows: rows)
    }

    func terminalDidSend(termID: String, _ bytes: Data) {
        guard let s = session(ofTerm: termID), s.live else { return }
        client.input(termID: termID, bytes: bytes)
    }

    /// The user typed, pasted or clicked in a live terminal.
    private func terminalActivity(termID: String) {
        guard let s = session(ofTerm: termID), s.live else { return }
        clearBell(termID: termID)
    }

    /// The user's own activity in a terminal clears its amber bell signal (M2);
    /// bytes the terminal sends by itself (a reply to a program's query) do not.
    private func clearBell(termID: String) {
        guard let board = ownerBoard(ofTerm: termID),
              let card = board.view.card(.term(termID)), card.bellActive else { return }
        card.setBell(false)
        board.view.signalsChanged()
    }

    /// Ensures the prime terminal is spawned (the boot terminal on a cold start).
    /// Further terminals are spawned by ⌘T (`spawnNewTerminal`) and by restore
    /// (`restoreTerminals`).
    func maybeSpawn() {
        // P5: gate on the active board's first restore. `helloOK` and the initial
        // `viewReady` async both race ahead of the restore; spawning the boot pty
        // before the restore decides re-bind-vs-cold would orphan a surviving
        // shell (the app would cold-spawn a second pty over it). The first restore
        // sets `didInitialRestore` then calls `maybeSpawn` itself, so a genuinely
        // cold prime still spawns — just after the re-bind decision, not before.
        // P5.3: while the active board awaits its reconnect revive, suppress the
        // spawn — its prime is detached (!live) but its shell may still be alive
        // daemon-side; cold-spawning now would orphan it. The revive (which sets
        // the prime live or respawns it) removes the board from the set first.
        guard connected, viewReady, activeBoard.didInitialRestore,
              !boardsAwaitingRevive.contains(activeBoardID),
              let s = primeSession, !s.live else { return }
        spawn(session: s)
    }

    /// Spawns a pty for `session` and seeds its card label / live state on `board`
    /// (the active board by default; passed explicitly when reviving / replacing a
    /// terminal on a possibly-backgrounded board).
    func spawn(session s: TerminalSession, on board: Board? = nil) {
        let board = board ?? activeBoard
        let cols = max(2, s.view.cols)
        let rows = max(2, s.view.rows)
        s.live = true
        s.lastSentCols = cols
        s.lastSentRows = rows
        client.spawnTerm(termID: s.termID, cols: cols, rows: rows, cwd: NSHomeDirectory(), cmd: nil)
        // cmd nil ⇒ the daemon spawns $SHELL (else /bin/zsh); mirror that
        // resolution for the card label — a fact known at spawn time.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        s.label = (shell as NSString).lastPathComponent
        s.shellName = s.label
        board.view.card(.term(s.termID))?.setTermLabel(s.label)
        board.view.card(.term(s.termID))?.setLive(false)
        // Cards restored before the term spawned get their gravity owner +
        // chip resolved now.
        rebindOwners()
        // The term card is now prime (focused terminal); doc cards go quiet.
        updatePrimacy(on: board)
    }

    /// ⌘T: spawns a new terminal card cascade-offset from the prime card (crib
    /// §6 decision 3), makes it prime + first responder, and persists it.
    func spawnNewTerminal() {
        guard connected, viewReady else { return }
        let id = BootTerminal.mint()
        let session = makeSession(termID: id)
        sessions[id] = session
        sessionOrder.append(id)
        termIndex.assign(termID: id, to: activeBoardID)
        activeBoard.view.setTerminal(termID: id, session.view, worldFrame: cascadeFrame())
        // Lay out so the terminal view has its card-sized geometry before spawn,
        // so the pty starts at the right cols/rows (not the 800×600 default).
        rootView.layoutSubtreeIfNeeded()
        // The new terminal becomes prime + first responder (typing follows it) AND
        // scroll-focused — so scrolling the freshly-spawned card scrolls its own
        // scrollback rather than panning the board. `spawn` recomputes both visuals.
        primeTermID = id
        focusedCardID = .term(id)
        spawn(session: session)
        activeBoard.view.select(.term(id))
        window?.makeFirstResponder(session.view)
        // Persist so the new terminal card survives a restart.
        persistLayout()
    }

    /// World frame for a new terminal card: cascade-offset down-right from the
    /// prime card, nudged off existing cards so repeated ⌘T stair-steps.
    private func cascadeFrame() -> CardFrame {
        let base = primeTermCard?.worldFrame ?? Place.termFrame
        let existing = activeBoard.view.cards.values.map { CGPoint(x: $0.worldFrame.x, y: $0.worldFrame.y) }
        let origin = BoardWayfinding.cascadeOrigin(
            base: CGPoint(x: base.x, y: base.y),
            existing: existing,
            dx: Place.cascadeDX,
            dy: Place.cascadeDY
        )
        let topZ = (activeBoard.view.cards.values.map(\.worldFrame.z).max() ?? 0) + 1
        return CardFrame(x: origin.x, y: origin.y, w: base.w, h: base.h, z: topZ)
    }

    /// 2606.0001: a shell exit ends the card's life per `TermExit.decide` — a
    /// clean exit removes the card (and replaces it when it was the board's last
    /// live terminal, or offers undo otherwise); an error/signal exit holds the
    /// card open as a read-only placeholder so the failure stays visible.
    func handleExit(termID: String, code: Int?) {
        // Resolve the OWNING board (the exit may be on a backgrounded board): the
        // teardown / prime advance happen on that board, not the active one.
        guard let board = ownerBoard(ofTerm: termID), let s = board.sessions[termID], s.live else { return }
        s.live = false
        termIndex.remove(termID: termID)
        let isActive = board === activeBoard
        guard let card = board.view.card(.term(termID)) else {
            // No card for the session (inconsistent state): drop the bookkeeping.
            advancePrime(on: board, after: termID)
            removeTerminalCard(termID: termID, on: board)
            if isActive { persistLayout() }
            refreshSwitcherIfOpen()
            return
        }
        // An exited terminal can't ring: clear any lingering bell.
        card.setBell(false)
        // OTHER terminals on this board still backed by a live pty (this one is
        // now !live) — drives the last-terminal guarantee.
        let otherLive = board.sessions.values.filter(\.live).count
        let frame = card.worldFrame

        switch TermExit.decide(code: code, otherLiveTerminals: otherLive) {
        case .holdOpen:
            // Error / signal exit: hold the card open as a read-only placeholder
            // so the failure stays visible. It stays in `sessionOrder`, but its
            // `dead` state excludes it from persistence; the user opens a fresh
            // terminal (⌘T) to keep working and closes the placeholder with ⌘W.
            card.setExited(code)
            board.view.signalsChanged()
            advancePrime(on: board, after: termID)
            feedNotice("shell exited (\(code.map { "exit \($0)" } ?? "killed by signal"))", to: s)
            let toastTitle = code.map { "shell exited · \($0)" } ?? "killed by signal"
            rootView.toasts.show(icon: "›_", title: toastTitle, body: nil)
        case .remove:
            // Clean exit, other live terminals remain: vanish + offer undo.
            // advancePrime runs while `termID` is still in `sessionOrder`, so it
            // can walk to a surviving terminal before the card is torn down.
            advancePrime(on: board, after: termID)
            removeTerminalCard(termID: termID, on: board)
            showUndoToast(on: board, at: frame)
        case .removeAndReplace:
            // Clean exit of the last live terminal: vanish, then spawn a fresh
            // boot terminal in its place so the board keeps ≥1 live terminal.
            advancePrime(on: board, after: termID)
            removeTerminalCard(termID: termID, on: board)
            spawnTerminal(on: board, at: frame)
        }

        // Persist (active board only) so the change survives a restart: a removed
        // or held-open terminal drops out of the snapshot per its lifecycle.
        if isActive { persistLayout() }
        refreshSwitcherIfOpen()
    }

    /// Tears down an exited terminal card on `board`: drops its session, its
    /// `sessionOrder` entry, and the card view, and clears scroll focus if it
    /// targeted this card. `termIndex` is cleared by `handleExit`; prime is moved
    /// by `advancePrime` first. Mirrors `adoptPrimeForRebind`'s teardown.
    private func removeTerminalCard(termID: String, on board: Board) {
        if board === activeBoard, focusedCardID == .term(termID) { focusedCardID = nil }
        board.sessions[termID] = nil
        board.sessionOrder.removeAll { $0 == termID }
        board.view.removeCard(id: .term(termID))
        board.view.signalsChanged()
    }

    /// Spawns a fresh boot terminal on `board` at `frame`, makes it that board's
    /// prime, and focuses it when `board` is active — a board-scoped twin of
    /// `spawnNewTerminal` at an explicit frame. Used by the clean-exit last-
    /// terminal replacement and by undo. Always mints a NEW `term_id` (never
    /// reuses the exited one).
    private func spawnTerminal(on board: Board, at frame: CardFrame) {
        let isActive = board === activeBoard
        let id = BootTerminal.mint()
        let session = makeSession(termID: id)
        board.sessions[id] = session
        board.sessionOrder.append(id)
        termIndex.assign(termID: id, to: board.boardID)
        board.view.setTerminal(termID: id, session.view, worldFrame: frame)
        board.primeTermID = id
        if isActive {
            focusedCardID = .term(id)
            // Lay out so the view has card-sized geometry before spawn, so the pty
            // starts at the right cols/rows (not the 800×600 view default).
            rootView.layoutSubtreeIfNeeded()
        }
        spawn(session: session, on: board)
        board.view.select(.term(id))
        if isActive { window?.makeFirstResponder(session.view) }
        persistLayout(for: board)
    }

    /// "shell closed · undo" toast after a clean exit. Undo cold-spawns a fresh
    /// shell (a NEW `term_id`) into the vanished card's slot on its board; if the
    /// toast is ignored / expires (~7 s) the removal is final.
    private func showUndoToast(on board: Board, at frame: CardFrame) {
        let boardID = board.boardID
        rootView.toasts.show(icon: "›_", title: "shell closed", body: nil, chips: [
            ("undo", { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let board = self.boards[boardID] else { return }
                    self.spawnTerminal(on: board, at: frame)
                }
            })
        ])
    }

    /// Terminates a focused terminal on the active board: kills its pty when
    /// `signalClose` says it is still live (the daemon SIGHUPs the group), then
    /// runs the clean-close teardown PROACTIVELY — not via
    /// the natural exit, since a SIGHUP exit reports as a signal and would hold the
    /// card open. Replaces it with a fresh shell when it was the last live terminal
    /// (≥1-terminal invariant), else offers undo. Mirrors `handleExit`'s clean arms;
    /// the late `Exit` is a no-op (the session is already gone).
    func closeTerminal(_ termID: String, replace: Bool, signalClose: Bool) {
        let board = activeBoard
        guard let card = board.view.card(.term(termID)) else { return }
        let frame = card.worldFrame
        if signalClose { client.termClose(termID: termID) }
        board.sessions[termID]?.live = false
        termIndex.remove(termID: termID)
        advancePrime(on: board, after: termID)
        removeTerminalCard(termID: termID, on: board)
        if replace {
            spawnTerminal(on: board, at: frame)
        } else {
            showUndoToast(on: board, at: frame)
        }
        persistLayout()
    }

    /// Moves `board`'s prime past the just-dead `deadID`: if it was that board's
    /// prime, advance to the next LIVE terminal in spawn order (wrapping), else
    /// just refresh styling. First responder is only moved when `board` is the
    /// active (mounted) one — a backgrounded board's prime change must not steal
    /// keyboard focus from the board the user is looking at.
    private func advancePrime(on board: Board, after deadID: String) {
        let isActive = board === activeBoard
        guard board.primeTermID == deadID else {
            updatePrimacy(on: board)
            return
        }
        let order = board.sessionOrder
        let n = order.count
        if n > 0, let deadIdx = order.firstIndex(of: deadID) {
            for offset in 1...n {
                let id = order[(deadIdx + offset) % n]
                if board.sessions[id]?.live == true {
                    board.primeTermID = id
                    updatePrimacy(on: board)
                    if isActive { window?.makeFirstResponder(board.sessions[id]?.view) }
                    return
                }
            }
        }
        // No live terminal remains on this board: nothing is prime. On the active
        // board, move first responder off the dead terminal view to the board so
        // the Return flight stays reachable (boardHasFocus would otherwise never be
        // true again until a board click).
        board.primeTermID = nil
        if isActive { window?.makeFirstResponder(rootView.board) }
        updatePrimacy(on: board)
    }

    /// Feeds a dim notice line into a terminal's scrollback — the given session,
    /// or the prime terminal when no session is named (e.g. a connect failure).
    func feedNotice(_ text: String, to session: TerminalSession? = nil) {
        (session?.view ?? primeTerminalView)?.feed(Data("\r\n\u{1b}[2m· \(text)\u{1b}[0m\r\n".utf8))
    }

    // MARK: - M2 honest signals (Phase 3.5)

    /// `.termProc`: the honest "card title = process name" — set the term card's
    /// header label to the foreground process name, replacing the shell basename
    /// set at spawn. The owner chips (`← <termname>`) follow the same label so
    /// they stay honest too.
    func handleTermProc(termID: String, name: String) {
        // Resolve the owning board (the proc may be on a backgrounded board); its
        // detached card state must stay honest because a re-visit re-mounts the
        // view rather than rebuilding it.
        guard let board = ownerBoard(ofTerm: termID), let s = board.sessions[termID], s.live else { return }
        // Track the foreground process name regardless of the displayed label —
        // an active OSC title hides it here but the card must revert to it when
        // that OSC title is later cleared.
        s.procName = name
        applyTermTitle(termID: termID, on: board)
    }

    /// A running program emitted an OSC 0/1/2 title. A non-empty title becomes
    /// the displayed label and takes precedence over the foreground process
    /// name; an empty title (programs clear with `ESC ] 2 ; ST`) clears the
    /// override and reverts to the process/shell fallback.
    func handleTermTitle(termID: String, title: String) {
        guard let board = ownerBoard(ofTerm: termID), let s = board.sessions[termID], s.live else { return }
        s.oscTitle = title.isEmpty ? nil : title
        applyTermTitle(termID: termID, on: board)
    }

    /// Shared UI plumbing for both title sources (OSC + `term_proc`): recompute the
    /// displayed label and the "live"/cyan status from `oscTitle` / `procName` /
    /// `shellName` via the pure `TermTitle` rules, then push them everywhere the
    /// honest label renders (card header, owner chips, switcher).
    private func applyTermTitle(termID: String, on board: Board) {
        guard let s = board.sessions[termID] else { return }
        let label = TermTitle.displayLabel(oscTitle: s.oscTitle, procName: s.procName, shellName: s.shellName)
        s.label = label
        let card = board.view.card(.term(termID))
        card?.setTermLabel(label)
        // "Live" (agent-active) when a program set its own OSC title, or — absent
        // that — when the foreground process is no longer the bare shell (crib §6:
        // cyan = agent-active).
        let live = TermTitle.isLive(oscTitle: s.oscTitle, procName: s.procName, shellName: s.shellName)
        card?.setLive(live)
        board.view.signalsChanged()
        // Re-render this board's attached doc cards' owner chips with the new label.
        for path in board.boardDocPaths {
            guard let docCard = board.view.card(.doc(path)) else { continue }
            docCard.setOwnerChip(ownerChipLabel(for: docCard, on: board))
        }
        refreshSwitcherIfOpen()
    }

    // MARK: - Phase 4 wayfinding (offscreen hints)

    /// Builds the offscreen-hint models (crib §6) for every signalling card:
    /// bell → `basename · HH:MM`; live → the process name. The board decides
    /// which are actually offscreen and where they pin. Priority orders the
    /// Return target (bell outranks live; among same, most-recent wins by z).
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
                label = signal == .bell ? "\(name) · \(nowHHMM())" : name
            case .doc(let path):
                let base = store.doc(for: path)?.fileName ?? (path as NSString).lastPathComponent
                label = signal == .bell ? "\(base) · \(nowHHMM())" : base
            }
            // Bell (amber) outranks live (cyan); break ties by z (most-recent on top).
            let priority = (signal == .bell ? 1000 : 0) + card.worldFrame.z
            hints.append(OffscreenHints.Hint(cardID: id, centerView: viewCenter, signal: signal, label: label, priority: priority))
        }
        return hints
    }

    // MARK: - ⌥tab terminal cycle + HUD (Phase 5a scaffold, crib §6)

    /// ⌥tab advances the prime (focused) terminal to the next LIVE terminal card
    /// in spawn order (wrapping) and flashes the cycle HUD with every live
    /// terminal's label, the new prime highlighted (crib §6). Dead terminals are
    /// skipped. With one terminal this re-asserts focus (a single-item HUD).
    func cycleTerminals() {
        let liveIDs = sessionOrder.filter { sessions[$0]?.live == true }
        guard !liveIDs.isEmpty else { return }
        let currentIdx = primeTermID.flatMap { liveIDs.firstIndex(of: $0) } ?? -1
        let nextIdx = (currentIdx + 1) % liveIDs.count
        setPrime(liveIDs[nextIdx])
        let labels = liveIDs.map { id -> String in
            let label = sessions[id]?.label ?? ""
            return label.isEmpty ? "shell" : label
        }
        rootView.cycleHUD.show(labels: labels, activeIndex: nextIdx)
    }

    private func nowHHMM() -> String {
        Self.hhmmFormatter.string(from: Date())
    }

    /// `.bell`: a BEL was seen on the terminal — give its card the amber bell
    /// signal. Cleared on the next keystroke or click in that terminal
    /// (see `clearBell(termID:)`).
    func handleBell(termID: String) {
        // Route to the owning board (a backgrounded board can ring); its detached
        // card lights amber and shows the signal on switch-back.
        guard let board = ownerBoard(ofTerm: termID), board.sessions[termID]?.live == true else { return }
        board.view.card(.term(termID))?.setBell(true)
        board.view.signalsChanged()
        refreshSwitcherIfOpen()
    }
}
