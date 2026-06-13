import AppKit
import SwiftTerm
import TarmacKit

/// Bridges SwiftTerm's non-isolated TerminalViewDelegate onto the MainActor
/// controller (callbacks arrive on the main thread in practice).
final class TermDelegateBridge: NSObject, TerminalViewDelegate {
    weak nonisolated(unsafe) var controller: AppController?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let controller else { return }
        MainActor.assumeIsolated { controller.terminalSizeChanged(cols: newCols, rows: newRows) }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let controller else { return }
        let bytes = Data(data)
        MainActor.assumeIsolated { controller.terminalDidSend(bytes) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    // The daemon is the authoritative BEL source (it reads the pty stream);
    // ignore the view-side echo.
    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class AppController {
    let client: DaemonClient
    let terminalView: TerminalView
    let rootView: RootView
    private weak var window: NSWindow?
    private let termDelegate = TermDelegateBridge()

    private var connected = false
    private var viewReady = false
    private var currentTermID: String?
    private var lastSentCols = 0
    private var lastSentRows = 0
    private var lastSpawnAt: Date?
    private var rapidExitCount = 0

    private let store = DocStore()
    private var escMonitor: Any?
    /// The viewport to fly back to when esc follows a Return flight (crib §6).
    /// Set by the Return flight; consumed (and cleared) by the next esc.
    private var preFlightViewport: Viewport?

    // MARK: - Cockpit dock / terminal primacy (Phase 5a)
    //
    // Whether the focused terminal is currently docked into the viewport-fixed
    // bottom pane (crib §4). Toggled by Return (board-focused) / esc.
    private var docked = false

    // MARK: - Shelf / gravity state (Phase 3)
    //
    // Shelf membership in chip order (open-but-unplaced docs); the source of
    // truth for the shelf overlay + persistence. Provenance owner per doc is
    // seeded from DocEntry.term_id and reapplied to landed cards.
    private var shelfPaths: [String] = []
    /// term_id → the term card it maps to. Single terminal this phase, so every
    /// known term_id resolves to `.term`; kept as a map so Phase 5 multi-term
    /// attribution slots in without touching the gravity code.
    private var ownerTermID: String?
    /// Provenance: doc path → the term_id that opened it (from DocEntry).
    private var docOwner: [String: String] = [:]
    /// The current terminal card label (for the owner chip `← <termname>`).
    private var termLabel: String = ""
    /// The shell basename resolved at spawn — the foreground process name equals
    /// this when the shell is idle (no agent running). Used to decide the term
    /// card's "live" (agent-active) signal for the wayfinding chrome.
    private var shellName: String = ""
    /// When the current non-shell foreground process started, for the locard's
    /// `<proc> · Ns` duration line (Phase 4 semantic zoom).
    private var liveProcSince: Date?

    // MARK: - Board placement rule (crib §4/§5)
    //
    // World-frame defaults for fresh placement and the M1→v4 restore scatter.
    // Sizes follow the crib's illustrative B2 frames (term 470×330, doc 392×310);
    // gaps are the illustrative ~86px horizontal / 32px vertical.
    private enum Place {
        static let termFrame = CardFrame(x: 80, y: 80, w: 470, h: 330, z: 0)
        static let docW: CGFloat = 392
        static let docH: CGFloat = 310
        static let gapX: CGFloat = 86
        static let gapY: CGFloat = 40
        static let docColumns = 2
    }

    init(window: NSWindow, rootView: RootView) {
        self.window = window
        self.rootView = rootView
        self.client = DaemonClient()

        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.font = Theme.mono(12)
        terminalView.nativeBackgroundColor = Theme.termBg
        terminalView.nativeForegroundColor = Theme.termFg
        terminalView.caretColor = Theme.text
        terminalView.optionAsMetaKey = true
        termDelegate.controller = self
        terminalView.terminalDelegate = termDelegate
        // The terminal is a board card like any other (crib §4); it lands near
        // the world origin and is reflowed on resize-commit.
        rootView.attachTerminal(terminalView, worldFrame: Place.termFrame)

        store.onChange = { [weak self] in self?.docsChanged() }
        rootView.peek.onPin = { [weak self] in self?.togglePinPeeked() }
        rootView.peek.onClose = { [weak self] in self?.hidePeek() }
        // Shelf chips: click → peek; drag onto the board → land a doc card at
        // the drop point's world position (crib §6).
        rootView.shelf.onChipClick = { [weak self] path in self?.openPeek(path) }
        rootView.shelf.onChipDropped = { [weak self] path, windowPoint in
            self?.landShelfDrop(path: path, windowPoint: windowPoint)
        }
        // Provenance edge label (crib §8): `tarmac open · HH:MM`, HH:MM from the
        // doc's lastOpenedMs in local time.
        rootView.board.edgeLabelProvider = { [weak self] id in self?.edgeLabel(for: id) }
        // A committed move/resize/zoom/pan on the board persists the full layout
        // snapshot (card world frames + board viewport); last-writer-wins.
        // TODO(perf): pan fires onLayoutChanged per scroll event — cheap LWW for
        // now; debounce/coalesce the layout send if pan persistence gets chatty.
        rootView.board.onLayoutChanged = { [weak self] _ in self?.persistLayout() }
        // Phase 4 wayfinding: supply the per-card offscreen-hint models (label +
        // priority) the board can't derive on its own (doc metadata / recency).
        rootView.offscreenHintProvider = { [weak self] in self?.offscreenHints() ?? [] }
    }

    func start() {
        client.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        client.onDisconnect = { [weak self] reason in
            MainActor.assumeIsolated { self?.handleDisconnect(reason) }
        }

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isEsc = event.keyCode == 53
            // Bare Return (no modifiers) toggles the dock / flies; ⌘⏎ is the
            // peek-pin menu key equivalent and is consumed before this monitor.
            let isReturn = event.keyCode == 36 && mods.isEmpty
            // ⌥tab (tab = keyCode 48 with the Option modifier, ignoring caps lock)
            // cycles the focused terminal among terminal cards + shows the HUD
            // (crib §6). With one terminal this is a no-op cycle (single HUD item).
            let isOptTab = event.keyCode == 48 && mods == .option
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if isOptTab {
                    self.cycleTerminals()
                    return true
                }
                // Return, when the board (not the terminal) holds focus and no
                // card gesture / peek / toast is up (crib §4/§6): if an offscreen
                // signal is waiting, fly the viewport to it (Phase 4); otherwise
                // toggle the cockpit dock (Phase 5a). Gated on board focus so the
                // shell's Enter key is never hijacked while typing.
                if isReturn, self.boardHasFocus() {
                    if !self.docked, let target = self.rootView.offscreenFlyTarget {
                        self.preFlightViewport = self.rootView.board.viewport
                        self.rootView.board.fly(to: target)
                        return true
                    }
                    self.toggleDock()
                    return true
                }
                guard isEsc else { return false }
                // An active board drag/resize swallows esc ahead of everything
                // (crib §5 DECISION; was desk.cancelDrag()).
                if self.rootView.board.cancelDrag() {
                    return true
                }
                // esc returns a docked terminal to its board card (crib §4),
                // ahead of the flight/fresh/peek/toast order.
                if self.docked {
                    self.undock()
                    return true
                }
                // esc after a Return flight flies the viewport back (crib §6).
                if let prev = self.preFlightViewport {
                    self.preFlightViewport = nil
                    self.rootView.board.flyTo(prev)
                    return true
                }
                // esc on a freshly-landed card sends it to the shelf (crib §5).
                if self.sendFreshCardToShelf() {
                    return true
                }
                if self.rootView.peekVisible {
                    self.hidePeek()
                    return true
                }
                if self.rootView.toasts.hasToasts {
                    self.rootView.toasts.clearAll()
                    return true
                }
                return false
            }
            return swallowed ? nil : event
        }

        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try client.connect()
            } catch {
                let detail = "\(error)"
                FileHandle.standardError.write(Data("tarmac: \(detail)\n".utf8))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in self?.showConnectFailure(detail) }
                }
            }
        }

        // Layout has happened by the next runloop turn; sizeChanged also flips
        // this, whichever lands first.
        DispatchQueue.main.async { [weak self] in
            self?.viewReady = true
            self?.maybeSpawn()
        }
    }

    // MARK: - Daemon messages

    private func handle(_ message: Message) {
        switch message {
        case .helloOK:
            connected = true
            maybeSpawn()
        case .restore(let docs, let tiles, let board):
            store.applyRestore(docs)
            // Seed provenance from the restored doc entries (term_id owner).
            for doc in docs {
                if let termID = doc.termID { docOwner[doc.path] = termID }
            }
            applyRestoredLayout(tiles: tiles, board: board)
            refreshStrips()
        case .output(let termID, let bytes):
            guard termID == currentTermID else { return }
            terminalView.feed(byteArray: [UInt8](bytes)[...])
        case .exit(let termID, let code):
            handleExit(termID: termID, code: code)
        case .docOpened(let doc):
            let wasOnBoard = isOnBoard(doc.path)
            store.applyDocOpened(doc)
            if let termID = doc.termID { docOwner[doc.path] = termID }
            // crib §5 / migration-plan Phase 3: a doc arriving via `tarmac open`
            // lands a FRESH card right of its caller term card (first free slot),
            // replacing the M1 toast. A user open keeps prior behavior (no card).
            if doc.via == "cli", !wasOnBoard, !shelfPaths.contains(doc.path) {
                landFreshCard(path: doc.path)
                // Persist the new board card so it survives a restart.
                persistLayout()
            }
            // A doc already on screen (peeked, or already a board card before this
            // open) is read immediately (crib-state §2.1). A brand-new fresh card
            // keeps its unread/fresh ring until the user touches it.
            if (rootView.peekVisible && peekPath == doc.path) || wasOnBoard {
                store.markRead(doc.path)
                client.docRead(path: doc.path)
                clearFreshIfRead(doc.path)
                if rootView.peekVisible && peekPath == doc.path {
                    refreshPeek(doc.path)
                }
            }
        case .fileEvent(let path, let mtimeMs):
            store.applyFileEvent(path: path, mtimeMs: mtimeMs)
            if isOnBoard(path) {
                rootView.board.card(.doc(path))?.renderDoc(markdown: readMarkdown(path))
            }
            if rootView.peekVisible && peekPath == path {
                refreshPeek(path)
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

    private func handleDisconnect(_ reason: String) {
        connected = false
        currentTermID = nil
        feedNotice("lost connection to tarmacd — \(reason)")
        rootView.toasts.show(title: "tarmacd connection lost", body: reason)
    }

    private func showConnectFailure(_ detail: String) {
        feedNotice(detail)
        rootView.toasts.show(title: "cannot reach tarmacd", body: "see terminal for details")
    }

    // MARK: - Terminal session

    func terminalSizeChanged(cols: Int, rows: Int) {
        viewReady = true
        maybeSpawn()
        guard let termID = currentTermID, cols > 0, rows > 0,
              cols != lastSentCols || rows != lastSentRows else { return }
        lastSentCols = cols
        lastSentRows = rows
        client.resize(termID: termID, cols: cols, rows: rows)
    }

    func terminalDidSend(_ bytes: Data) {
        guard let termID = currentTermID else { return }
        // A keystroke to the terminal clears its amber bell signal (M2).
        clearBell()
        client.input(termID: termID, bytes: bytes)
    }

    private func maybeSpawn() {
        guard connected, viewReady, currentTermID == nil else { return }
        let term = terminalView.getTerminal()
        let cols = max(2, term.cols)
        let rows = max(2, term.rows)
        let termID = UUID().uuidString
        currentTermID = termID
        ownerTermID = termID
        lastSentCols = cols
        lastSentRows = rows
        lastSpawnAt = Date()
        client.spawnTerm(termID: termID, cols: cols, rows: rows, cwd: NSHomeDirectory(), cmd: nil)
        // cmd nil ⇒ the daemon spawns $SHELL (else /bin/zsh); mirror that
        // resolution for the card label — a fact known at spawn time.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        termLabel = (shell as NSString).lastPathComponent
        shellName = termLabel
        liveProcSince = nil
        rootView.board.card(.term)?.setTermLabel(termLabel)
        rootView.board.card(.term)?.setLive(false)
        refreshTermLocard()
        // Cards restored before the term spawned get their gravity owner +
        // chip resolved now (the term_id only becomes known at spawn).
        rebindOwners()
        // The term card is now prime (focused terminal); doc cards go quiet.
        updatePrimacy()
    }

    private func handleExit(termID: String, code: Int?) {
        guard termID == currentTermID else { return }
        currentTermID = nil
        // A dead terminal can't ring: clear any lingering bell signal.
        clearBell()
        // No live terminal ⇒ nothing is prime; drop prime/quiet styling.
        updatePrimacy()
        let label = code.map { "exit \($0)" } ?? "killed by signal"
        feedNotice("shell exited (\(label)) — restarting…")
        // Exit toast (M2 honest signals): title "shell exited · <code>" (or
        // "killed by signal" when code is nil).
        let toastTitle = code.map { "shell exited · \($0)" } ?? "killed by signal"
        rootView.toasts.show(icon: "›_", title: toastTitle, body: nil)

        if let spawnedAt = lastSpawnAt, Date().timeIntervalSince(spawnedAt) < 1.0 {
            rapidExitCount += 1
        } else {
            rapidExitCount = 0
        }
        guard rapidExitCount < 3 else {
            feedNotice("shell keeps exiting immediately — auto-respawn stopped")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.connected, self.currentTermID == nil else { return }
                self.maybeSpawn()
            }
        }
    }

    private func feedNotice(_ text: String) {
        terminalView.feed(text: "\r\n\u{1b}[2m· \(text)\u{1b}[0m\r\n")
    }

    // MARK: - M2 honest signals (Phase 3.5)

    /// `.termProc`: the honest "card title = process name" — set the term card's
    /// header label to the foreground process name, replacing the shell basename
    /// set at spawn. The owner chips (`← <termname>`) follow the same label so
    /// they stay honest too.
    private func handleTermProc(termID: String, name: String) {
        guard termID == currentTermID else { return }
        termLabel = name
        rootView.board.card(.term)?.setTermLabel(name)
        // Keep the dock header label honest while docked (crib §4 .dhd label).
        if docked { rootView.dockPane.setTermLabel(name.isEmpty ? "shell" : name) }
        // "Live" (agent-active) when the foreground process is no longer the bare
        // shell (crib §6: cyan = agent-active). The honest signal we have at this
        // phase is the foreground process name; treat shell == idle.
        let live = !name.isEmpty && name != shellName
        let card = rootView.board.card(.term)
        let wasLive = card?.liveActive ?? false
        if live, !wasLive { liveProcSince = Date() }
        if !live { liveProcSince = nil }
        card?.setLive(live)
        rootView.board.signalsChanged()
        refreshTermLocard()
        // Re-render any attached doc card's owner chip with the new term name.
        for path in boardDocPaths {
            guard let card = rootView.board.card(.doc(path)) else { continue }
            card.setOwnerChip(ownerChipLabel(for: card))
        }
    }

    // MARK: - Phase 4 wayfinding (locard content, offscreen hints)

    /// Feeds the terminal card's locard content (crib §7): the foreground process
    /// name + a duration (`<proc> · Ns`) when live, else the shell name idle.
    private func refreshTermLocard() {
        guard let card = rootView.board.card(.term) else { return }
        let status: String
        if card.liveActive, let since = liveProcSince {
            let secs = max(1, Int(Date().timeIntervalSince(since).rounded()))
            status = "running · \(secs)s"
        } else {
            status = "idle"
        }
        card.setLocardContent(name: termLabel.isEmpty ? "shell" : termLabel, status: status, repoColor: nil)
    }

    /// Feeds a doc card's locard content (crib §7): basename + recency line.
    private func refreshDocLocard(_ path: String) {
        guard let card = rootView.board.card(.doc(path)), let doc = store.doc(for: path) else { return }
        let status = doc.read ? doc.displayPath : "unread · \(doc.displayPath)"
        let color = Theme.repoColor(index: doc.repoColor, fallbackName: doc.displayRepoName)
        card.setLocardContent(name: doc.fileName, status: status, repoColor: color)
    }

    /// Builds the offscreen-hint models (crib §6) for every signalling card:
    /// bell → `basename · HH:MM`; live → the process name. The board decides
    /// which are actually offscreen and where they pin. Priority orders the
    /// Return target (bell outranks live; among same, most-recent wins by z).
    private func offscreenHints() -> [OffscreenHints.Hint] {
        var hints: [OffscreenHints.Hint] = []
        for (id, card) in rootView.board.cards {
            let signal = card.signal
            guard signal != .none else { continue }
            let viewCenter = CGPoint(x: card.frame.midX, y: card.frame.midY)
            let label: String
            switch id {
            case .term:
                label = signal == .bell ? "\(termLabel) · \(nowHHMM())" : termLabel
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

    /// True when keyboard focus is on the board rather than the terminal — so a
    /// bare Return triggers the offscreen flight instead of the shell's Enter
    /// (crib §6 focus model). The terminal is the default first responder; the
    /// board takes focus only when the user clicks its background.
    private func boardHasFocus() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === terminalView { return false }
        if let view = responder as? NSView, view.isDescendant(of: terminalView) { return false }
        // The board view itself (or a non-terminal board descendant) is focused.
        if let view = responder as? NSView, view.isDescendant(of: rootView.board) { return true }
        return responder === rootView.board
    }

    // MARK: - Terminal primacy: prime / quiet focus model (Phase 5a, crib §4)

    /// Applies the prime/quiet card states (crib §4). With a single terminal the
    /// term card is the prime card (focused terminal: `#5a626a` border, `#3a4046`
    /// header, deeper shadow) and every other (doc) card is quiet (opacity 0.8).
    /// Called whenever the card set / focus changes. Phase 5b will make "which
    /// terminal is prime" follow the cycle; here it is always the one term card.
    private func updatePrimacy() {
        let primeID: CardID? = currentTermID == nil ? nil : .term
        for (id, card) in rootView.board.cards {
            let isPrime = (id == primeID)
            card.setPrime(isPrime)
            // A card is quiet only while some terminal is prime and it isn't it.
            card.setQuiet(primeID != nil && !isPrime)
        }
    }

    // MARK: - Cockpit dock (Phase 5a, crib §4)

    /// Return (board-focused) toggles the dock; esc always undocks.
    private func toggleDock() {
        if docked { undock() } else { dock() }
    }

    /// Docks the focused terminal into the viewport-fixed bottom pane (crib §4):
    /// REPARENT the SwiftTerm view from its board card body into the dock pane,
    /// hide the board card + show its dashed slot ghost, then reflow + restore
    /// first responder so the terminal keeps typing.
    private func dock() {
        guard !docked, currentTermID != nil else { return }
        docked = true
        // Reparent the live SwiftTerm view: card body → dock pane body.
        terminalView.removeFromSuperview()
        rootView.dockPane.body.addSubview(terminalView)
        rootView.dockPane.setTermLabel(termLabel.isEmpty ? "shell" : termLabel)
        rootView.setDockVisible(true)
        rootView.board.setDocked(.term)
        // Reflow into the dock body's geometry, then restore first responder so
        // keystrokes still land in the terminal (the delegate is unchanged).
        // Lay out RootView first so the dock pane has its (just-shown) frame,
        // then the pane subtree positions the reparented terminal.
        rootView.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(terminalView)
        forceTerminalReflow()
        updatePrimacy()
    }

    /// Returns the docked terminal to its board card (crib §4): REPARENT the
    /// SwiftTerm view dock pane body → card body, hide the dock pane + slot ghost,
    /// reflow + restore first responder.
    private func undock() {
        guard docked else { return }
        docked = false
        terminalView.removeFromSuperview()
        rootView.board.card(.term)?.attachTerminal(terminalView)
        rootView.setDockVisible(false)
        rootView.board.setDocked(nil)
        // Reflow into the card body's geometry, then restore first responder.
        rootView.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(terminalView)
        forceTerminalReflow()
        updatePrimacy()
    }

    /// Nudges the terminal to re-measure its cols/rows after a reparent so the
    /// daemon pty resizes to the new geometry. SwiftTerm reflows on a frame
    /// change; `terminalSizeChanged` then forwards the resize to the daemon.
    private func forceTerminalReflow() {
        // A layout pass already ran; re-assert the current size to the daemon in
        // case the cols/rows are unchanged but the view was reparented.
        let term = terminalView.getTerminal()
        terminalSizeChanged(cols: term.cols, rows: term.rows)
    }

    // MARK: - ⌥tab terminal cycle + HUD (Phase 5a scaffold, crib §6)

    /// ⌥tab cycles the focused terminal among terminal cards and flashes the
    /// cycle HUD (crib §6). With one terminal this is a visual no-op (a single
    /// HUD item); kept real so Phase 5b can populate the cycle without rewiring.
    private func cycleTerminals() {
        let labels = terminalCycleLabels()
        guard !labels.isEmpty else { return }
        // Single terminal ⇒ the active item is always index 0. Phase 5b advances
        // this index across the real terminal-card set.
        rootView.cycleHUD.show(labels: labels, activeIndex: 0)
        // Typing always goes to the prime terminal regardless of pointer (crib
        // §6 focus model): re-assert first responder on the focused terminal.
        if !docked { window?.makeFirstResponder(terminalView) }
    }

    /// The terminal-card names for the cycle HUD (crib §6). One entry this phase
    /// (the single term card's current label).
    private func terminalCycleLabels() -> [String] {
        guard currentTermID != nil else { return [] }
        return [termLabel.isEmpty ? "shell" : termLabel]
    }

    private func nowHHMM() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date())
    }

    /// `.bell`: a BEL was seen on the terminal — give its card the amber bell
    /// signal. Cleared on the next keystroke to that terminal or on focus
    /// (see `terminalDidSend` / `clearBell`).
    private func handleBell(termID: String) {
        guard termID == currentTermID else { return }
        rootView.board.card(.term)?.setBell(true)
        rootView.board.signalsChanged()
    }

    /// Clears the amber bell signal on the term card (next keystroke / focus).
    private func clearBell() {
        rootView.board.card(.term)?.setBell(false)
        rootView.board.signalsChanged()
    }

    // MARK: - Board layout (restore + persistence)

    /// `restore.tiles[]` → board cards + shelf chips (crib §6). A `shelf:true`
    /// doc tile becomes a shelf chip; a geometry-bearing doc tile becomes a
    /// board card seeded from the doc's provenance owner (attached = !loose); a
    /// geometry-less, non-shelf doc tile is an M1 layout → default scatter
    /// migration. The terminal card always survives. Unknown kinds and
    /// unregistered doc paths are skipped (protocol receiver rules). The board
    /// viewport is applied when present, else the default.
    private func applyRestoredLayout(tiles: [LayoutTile], board: BoardViewport?) {
        // Tear down any doc cards from a prior restore; the term card is kept and
        // re-placed (its embedded SwiftTerm view stays attached). Snapshot the ids
        // first — removeCard mutates the board's `cards` dictionary.
        for id in Array(rootView.board.cards.keys) {
            if case .doc = id { rootView.board.removeCard(id: id) }
        }
        shelfPaths = []

        var docSlot = 0
        var migratedAny = false
        for tile in tiles {
            switch tile.kind {
            case "term":
                let stored = CardFrame(tile: tile)
                if stored == nil { migratedAny = true }
                rootView.board.setTerminal(terminalView, worldFrame: stored ?? Place.termFrame)
            case "doc":
                guard let path = tile.path, store.doc(for: path) != nil else { continue }
                if tile.shelf == true {
                    if !shelfPaths.contains(path) { shelfPaths.append(path) }
                    continue
                }
                if let stored = CardFrame(tile: tile) {
                    landDocCard(path: path, frame: stored, attached: tile.loose != true, fresh: false)
                } else {
                    // Geometry-less, non-shelf doc tile: M1 migration → scatter.
                    migratedAny = true
                    landDocCard(path: path, frame: scatterFrame(docSlot: docSlot), attached: tile.loose != true, fresh: false)
                }
                docSlot += 1
            default:
                continue // unknown kind: skip (protocol receiver rule)
            }
        }

        if migratedAny {
            let origin = "\(Int(Place.termFrame.x)),\(Int(Place.termFrame.y))"
            let docSize = "\(Int(Place.docW))×\(Int(Place.docH))"
            let log = "tarmac: migrated M1 layout → default scatter "
                + "(term near origin at \(origin); doc cards \(docSize) in a "
                + "\(Place.docColumns)-col grid right of the terminal)\n"
            FileHandle.standardError.write(Data(log.utf8))
        }

        rootView.board.setViewport(board.map(Viewport.init) ?? .default)
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

    /// Adds (or replaces) a doc card, renders its content, and seeds gravity:
    /// ownerTermID from the doc's provenance + the attached flag (owner chip
    /// shown while attached). `fresh` gives the just-spawned ring + `✚ now`.
    @discardableResult
    private func landDocCard(path: String, frame: CardFrame, attached: Bool, fresh: Bool) -> CardView {
        let card = rootView.board.addCard(id: .doc(path), worldFrame: frame)
        if let doc = store.doc(for: path) { card.apply(doc: doc) }
        card.ownerTermID = ownerCardID(for: path)
        card.attached = attached && card.ownerTermID != nil
        if fresh { card.setFresh(true) }
        card.setOwnerChip(ownerChipLabel(for: card))
        card.renderDoc(markdown: readMarkdown(path))
        refreshDocLocard(path)
        rootView.board.recomputeEdges()
        // A doc card is quiet while a terminal is prime (crib §4).
        if currentTermID != nil { card.setQuiet(true) }
        return card
    }

    /// The board CardID of a doc's provenance owner term card, when resolvable
    /// (single terminal this phase: any known owner term_id resolves to .term).
    private func ownerCardID(for path: String) -> CardID? {
        guard let owner = docOwner[path], owner == ownerTermID else { return nil }
        return .term
    }

    /// `← <termname>` chip text for an attached doc card, else nil.
    private func ownerChipLabel(for card: CardView) -> String? {
        guard card.attached, card.ownerTermID != nil else { return nil }
        return termLabel.isEmpty ? nil : termLabel
    }

    /// Re-resolves doc-card owners + chips once the term_id becomes known (the
    /// term spawns after restore). Called from maybeSpawn.
    private func rebindOwners() {
        for path in boardDocPaths {
            guard let card = rootView.board.card(.doc(path)) else { continue }
            // Only (re)bind cards that were restored attached; a detached card
            // stays detached.
            if card.ownerTermID == nil, card.attached, docOwner[path] == ownerTermID {
                card.ownerTermID = .term
            }
            card.setOwnerChip(ownerChipLabel(for: card))
        }
        rootView.board.recomputeEdges()
    }

    // MARK: - Fresh card landing (crib §5)

    /// The path of the most-recent fresh (just-landed CLI) card, if its card is
    /// still fresh; esc targets it for the shelf.
    private var freshCardPath: String?

    /// Lands a fresh doc card to the right of its caller term card via a
    /// first-free-slot search; gives it the fresh ring + `✚ now` meta.
    private func landFreshCard(path: String) {
        let frame = firstFreeSlot()
        landDocCard(path: path, frame: frame, attached: true, fresh: true)
        freshCardPath = path
    }

    /// First-free-slot search (crib §5): start at the caller term card's right
    /// edge + ~gapX, find a docW×docH world rect not overlapping existing cards,
    /// scanning right then down.
    private func firstFreeSlot() -> CardFrame {
        let term = rootView.board.card(.term)?.worldFrame ?? Place.termFrame
        let startX = term.x + term.w + Place.gapX
        let startY = term.y
        let stepX = Place.docW + Place.gapX
        let stepY = Place.docH + Place.gapY
        let existing = rootView.board.cards.values.map(\.worldFrame.rect)
        let topZ = (rootView.board.cards.values.map(\.worldFrame.z).max() ?? 0) + 1
        for row in 0..<64 {
            for col in 0..<64 {
                let candidate = CGRect(
                    x: startX + CGFloat(col) * stepX,
                    y: startY + CGFloat(row) * stepY,
                    width: Place.docW,
                    height: Place.docH
                )
                let clash = existing.contains { $0.intersects(candidate.insetBy(dx: -8, dy: -8)) }
                if !clash {
                    return CardFrame(rect: candidate, z: topZ)
                }
            }
        }
        // Fallback: stack a little past the term card.
        return CardFrame(x: startX, y: startY, w: Place.docW, h: Place.docH, z: topZ)
    }

    /// Marking a doc read clears its fresh ring (crib §5).
    private func clearFreshIfRead(_ path: String) {
        guard let card = rootView.board.card(.doc(path)), card.fresh else { return }
        card.setFresh(false)
        if freshCardPath == path { freshCardPath = nil }
    }

    /// esc sends a still-fresh card to the shelf (crib §5): set its tile
    /// shelf:true, remove the board card, persist. Returns false when there is
    /// no fresh card so esc falls through to peek/toast dismissal.
    @discardableResult
    private func sendFreshCardToShelf() -> Bool {
        guard let path = freshCardPath, let card = rootView.board.card(.doc(path)), card.fresh else {
            freshCardPath = nil
            return false
        }
        freshCardPath = nil
        moveToShelf(path)
        return true
    }

    /// Moves a doc from the board to the shelf, persists, refreshes.
    private func moveToShelf(_ path: String) {
        rootView.board.removeCard(id: .doc(path))
        if !shelfPaths.contains(path) { shelfPaths.append(path) }
        persistLayout()
        refreshStrips()
    }

    /// Lands a shelf chip dragged onto the board at the drop point's world
    /// position (crib §6). Removes it from the shelf and persists.
    private func landShelfDrop(path: String, windowPoint: NSPoint) {
        guard store.doc(for: path) != nil else { return }
        shelfPaths.removeAll { $0 == path }
        let viewPoint = rootView.board.convert(windowPoint, from: nil)
        let world = rootView.board.viewToWorld(viewPoint)
        let topZ = (rootView.board.cards.values.map(\.worldFrame.z).max() ?? 0) + 1
        // Drop point is the card's top-left.
        let frame = CardFrame(x: world.x, y: world.y, w: Place.docW, h: Place.docH, z: topZ)
        // A shelf doc lands detached (it had no board placement / gravity tie).
        landDocCard(path: path, frame: frame, attached: false, fresh: false)
        persistLayout()
        refreshStrips()
    }

    /// Doc paths currently on the board.
    private var boardDocPaths: [String] {
        rootView.board.cards.keys.compactMap {
            if case .doc(let path) = $0 { return path }
            return nil
        }
    }

    private func isOnBoard(_ path: String) -> Bool {
        rootView.board.card(.doc(path)) != nil
    }

    /// Reports the full layout snapshot (docs/protocol.md `layout`;
    /// last-writer-wins): the terminal card frame, each board doc card's frame
    /// with its `loose` flag (shelf:false), and each shelf doc as a geometry-less
    /// `shelf:true` tile. Plus the board viewport `{zoom,cx,cy}`. Fired on every
    /// committed board move/resize/zoom/pan, and on shelf/gravity changes.
    private func persistLayout() {
        var tiles: [LayoutTile] = []
        if let term = rootView.board.card(.term) {
            tiles.append(boardTile(kind: "term", path: nil, card: term))
        }
        for path in boardDocPaths.sorted() {
            guard let card = rootView.board.card(.doc(path)) else { continue }
            tiles.append(boardTile(kind: "doc", path: path, card: card))
        }
        // Shelf docs: kind "doc", shelf:true, loose:true, no geometry (crib §6).
        for path in shelfPaths {
            tiles.append(LayoutTile(kind: "doc", path: path, loose: true, shelf: true))
        }
        client.layout(
            dock: store.docs.map(\.path),
            tiles: tiles,
            board: rootView.board.viewport.wire
        )
    }

    /// A board card → tile: its world frame, `loose` = !attached, shelf:false.
    private func boardTile(kind: String, path: String?, card: CardView) -> LayoutTile {
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
            shelf: kind == "doc" ? false : nil
        )
    }

    // MARK: - Docs / peek

    private var peekPath: String? { rootView.peek.currentPath }

    private func docsChanged() {
        // Drop shelf entries for docs the registry no longer knows (defensive).
        shelfPaths.removeAll { store.doc(for: $0) == nil }
        refreshStrips()
    }

    /// Rebuilds the shelf chips, syncs on-board card headers (incl. owner chips)
    /// with the registry, and updates the status-bar counts + cold-start hint.
    private func refreshStrips() {
        rootView.shelf.update(items: shelfPaths.compactMap(shelfItem(for:)))
        for path in boardDocPaths {
            guard let card = rootView.board.card(.doc(path)) else { continue }
            if let doc = store.doc(for: path) { card.apply(doc: doc) }
            card.setOwnerChip(ownerChipLabel(for: card))
            refreshDocLocard(path)
        }
        rootView.statusBar.setCounts(board: boardDocPaths.count, shelf: shelfPaths.count)
        rootView.coldStartHint.isHidden = !store.isEmpty
    }

    /// Builds a shelf chip model from the registry (repo dot + basename + an
    /// agent unread dot when unread).
    private func shelfItem(for path: String) -> ShelfItem? {
        guard let doc = store.doc(for: path) else { return nil }
        return ShelfItem(
            path: path,
            basename: doc.fileName,
            repoColor: doc.repoColor,
            fallbackName: doc.displayRepoName,
            unread: !doc.read
        )
    }

    /// `tarmac open · HH:MM` edge label (crib §8): HH:MM from the doc's
    /// lastOpenedMs in local time. nil when the doc/time is unknown.
    private func edgeLabel(for id: CardID) -> String? {
        guard case .doc(let path) = id, let doc = store.doc(for: path), let ms = doc.lastOpenedMs else {
            return nil
        }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        return "tarmac open · \(fmt.string(from: date))"
    }

    /// ⌘P: peek (or re-target) the most-recent doc — never closes an open peek
    /// (crib-state §6 supersedes M0's toggle).
    func peekRecent() {
        guard let path = store.mostRecentPath else {
            NSSound.beep()
            return
        }
        openPeek(path)
    }

    func openPeek(_ path: String) {
        rootView.peek.present(path: path, doc: store.doc(for: path), markdown: readMarkdown(path))
        rootView.setPeekVisible(true)
        // Presentation marks read; doc_read is idempotent and sent every time.
        store.markRead(path)
        client.docRead(path: path)
        clearFreshIfRead(path)
        refreshStrips()
        // Focus rule: opening a peek never moves keyboard focus off the terminal.
        window?.makeFirstResponder(terminalView)
    }

    func hidePeek() {
        rootView.setPeekVisible(false)
        refreshStrips()
        window?.makeFirstResponder(terminalView)
        // Focus returns to the terminal: clear any amber bell signal (M2).
        clearBell()
    }

    /// ⌘⏎ (key or peek-header chip): land the peeked doc as a card at the gravity
    /// position (first free slot right of the caller term card), or remove it if
    /// already placed, closing the peek either way. No 4-tile cap (the cap was a
    /// grid-template constraint — removed per Phase 2).
    func togglePinPeeked() {
        guard rootView.peekVisible, let path = peekPath else { return }
        if isOnBoard(path) {
            rootView.board.removeCard(id: .doc(path))
        } else {
            shelfPaths.removeAll { $0 == path }
            // Land at the gravity position; attach when the doc has a resolvable
            // owner, so it follows the term card and shows the owner chip.
            let attached = ownerCardID(for: path) != nil
            landDocCard(path: path, frame: firstFreeSlot(), attached: attached, fresh: false)
        }
        persistLayout()
        refreshStrips()
        hidePeek()
    }

    private func refreshPeek(_ path: String) {
        rootView.peek.present(path: path, doc: store.doc(for: path), markdown: readMarkdown(path))
    }

    private func readMarkdown(_ path: String) -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return "could not read `\(path)`\n\n```\n\(error.localizedDescription)\n```\n"
        }
    }
}
