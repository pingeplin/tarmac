import AppKit
import SwiftTerm
import TarmacKit

/// Bridges SwiftTerm's non-isolated TerminalViewDelegate onto the MainActor
/// controller (callbacks arrive on the main thread in practice). Phase 5b: each
/// terminal view has its own bridge carrying its `term_id`, so size/input
/// callbacks self-identify their pty (no global "current" terminal).
final class TermDelegateBridge: NSObject, TerminalViewDelegate {
    weak nonisolated(unsafe) var controller: AppController?
    let termID: String

    init(termID: String) {
        self.termID = termID
        super.init()
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let controller else { return }
        let id = termID
        MainActor.assumeIsolated { controller.terminalSizeChanged(termID: id, cols: newCols, rows: newRows) }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let controller else { return }
        let bytes = Data(data)
        let id = termID
        MainActor.assumeIsolated { controller.terminalDidSend(termID: id, bytes) }
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

/// One terminal card's live state (Phase 5b: the board holds N of these). Owns
/// the SwiftTerm view + its delegate bridge and the per-terminal signal/process
/// bookkeeping that used to be controller-global. `live` is whether the pty is
/// running (false before first spawn and after exit). The exited/dead visual
/// state lives on the board card (`CardView.dead`), not here.
@MainActor
final class TerminalSession {
    let termID: String
    let view: TerminalView
    let bridge: TermDelegateBridge
    /// Whether the pty backing this card is currently running.
    var live = false
    /// Header label: the foreground process name, or the shell basename idle.
    var label = ""
    /// The shell basename resolved at spawn — idle ⇔ foreground == shellName.
    var shellName = ""
    /// When the current non-shell foreground process started (locard duration).
    var liveProcSince: Date?
    /// Last cols/rows sent to the daemon — debounces duplicate resizes.
    var lastSentCols = 0
    var lastSentRows = 0

    init(termID: String, view: TerminalView, bridge: TermDelegateBridge) {
        self.termID = termID
        self.view = view
        self.bridge = bridge
    }
}

@MainActor
final class AppController {
    let client: DaemonClient
    let rootView: RootView
    private weak var window: NSWindow?

    private var connected = false
    private var viewReady = false

    private var escMonitor: Any?

    // MARK: - Boards (M3 P3)
    //
    // The app holds N boards keyed by `board_id`; `activeBoard` is the one the
    // user is looking at (its `view` is the mounted BoardView). board-0 wraps
    // today's single board losslessly. The board-scoped state — sessions, prime,
    // dock, shelf, provenance, fresh card, restore latch — lives on `Board`; the
    // shims below keep AppController's existing call sites compiling while that
    // state delegates to whichever board is active, so once the real switch
    // lands every read/write automatically targets the right board.
    private var boards: [String: Board] = [:]
    private var activeBoardID = Board.defaultID
    /// The active board. Force-unwrapped: `boards` always contains
    /// `activeBoardID` (the invariant the boot path + the switch path maintain).
    private var activeBoard: Board { boards[activeBoardID]! }

    /// term_id → board_id ownership index (set at spawn, cleared at exit). Routes
    /// the daemon's term-keyed frames (output / exit / signals) to the OWNING
    /// board — so a backgrounded board's output feeds its detached view and its
    /// card signals update the right board, never the active one.
    private var termIndex = TermBoardIndex()

    /// The board that owns `termID` (via the term→board index), or nil if the
    /// term is unknown / already exited.
    private func ownerBoard(ofTerm termID: String) -> Board? {
        guard let bid = termIndex.board(of: termID) else { return nil }
        return boards[bid]
    }

    /// The session backing `termID` on its owning board, across all boards.
    private func session(ofTerm termID: String) -> TerminalSession? {
        ownerBoard(ofTerm: termID)?.sessions[termID]
    }

    /// The active board's doc registry (each board owns its own). The bulk of the
    /// chrome (shelf, peek, locards, ⌘P, counts) reads the active board's docs;
    /// the few cross-board mutations (a `tarmac open` / file event for a doc on a
    /// backgrounded board) target that board's store explicitly.
    private var store: DocStore { activeBoard.store }

    /// M3 P3 switch tracing (temporary): set TARMAC_DEBUG_SWITCH to log the
    /// board-switch lifecycle to stderr. Removed once the switch is verified.
    private static let switchDebug = ProcessInfo.processInfo.environment["TARMAC_DEBUG_SWITCH"] != nil
    private func dbg(_ s: @autoclosure () -> String) {
        guard Self.switchDebug else { return }
        FileHandle.standardError.write(Data("tarmac[switch]: \(s())\n".utf8))
    }

    private var sessions: [String: TerminalSession] {
        get { activeBoard.sessions }
        set { activeBoard.sessions = newValue }
    }
    private var sessionOrder: [String] {
        get { activeBoard.sessionOrder }
        set { activeBoard.sessionOrder = newValue }
    }
    private var primeTermID: String? {
        get { activeBoard.primeTermID }
        set { activeBoard.primeTermID = newValue }
    }
    private var docked: Bool {
        get { activeBoard.docked }
        set { activeBoard.docked = newValue }
    }
    private var shelfPaths: [String] {
        get { activeBoard.shelfPaths }
        set { activeBoard.shelfPaths = newValue }
    }
    private var docOwner: [String: String] {
        get { activeBoard.docOwner }
        set { activeBoard.docOwner = newValue }
    }
    private var freshCardPath: String? {
        get { activeBoard.freshCardPath }
        set { activeBoard.freshCardPath = newValue }
    }
    private var preFlightViewport: Viewport? {
        get { activeBoard.preFlightViewport }
        set { activeBoard.preFlightViewport = newValue }
    }
    private var didInitialRestore: Bool {
        get { activeBoard.didInitialRestore }
        set { activeBoard.didInitialRestore = newValue }
    }
    // Read-only computed accessors (pure functions of the active board's state).
    private var primeSession: TerminalSession? { activeBoard.primeSession }
    private var primeTerminalView: TerminalView? { activeBoard.primeTerminalView }
    private var primeTermCard: CardView? { activeBoard.primeTermCard }
    private var hasLivePrime: Bool { activeBoard.hasLivePrime }
    private var boardDocPaths: [String] { activeBoard.boardDocPaths }

    // M3: the app tracks the board list + the active board from `board_list`
    // (P4 renders the ⌘K switcher from it).
    private var boardMetas: [BoardMeta] = []
    // True from a switch's leave until its arrive completes. Suppresses layout
    // persistence across the transient (undock / unmount / re-mount / rebuild)
    // and tells the restore handler to mount the arriving board (crit B4).
    private var switching = false

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
        // ⌘T new-terminal cascade offset (down-right from the prime card).
        static let cascadeDX: CGFloat = 43
        static let cascadeDY: CGFloat = 40
    }

    init(window: NSWindow, rootView: RootView) {
        self.window = window
        self.rootView = rootView
        self.client = DaemonClient()

        // M3: board-0 wraps the single BoardView that exists today; until the
        // P3 switch lands it is the only board and is always active + mounted.
        let board0 = Board(boardID: Board.defaultID, view: rootView.board)
        self.boards = [board0.boardID: board0]
        self.activeBoardID = board0.boardID

        // Mint the boot terminal's id up front so its board card and its pty
        // share an id from creation (Phase 5b keys cards by term_id). The
        // terminal is a board card like any other (crib §4), reflowed on
        // resize-commit.
        let bootTermID = BootTerminal.mint()
        let boot = makeSession(termID: bootTermID)
        board0.sessions[bootTermID] = boot
        board0.sessionOrder = [bootTermID]
        board0.primeTermID = bootTermID
        termIndex.assign(termID: bootTermID, to: board0.boardID)
        rootView.attachTerminal(boot.view, termID: bootTermID, worldFrame: Place.termFrame)

        wireStore(board0)
        rootView.peek.onPin = { [weak self] in self?.togglePinPeeked() }
        rootView.peek.onClose = { [weak self] in self?.hidePeek() }
        // Shelf chips: click → peek; drag onto the board → land a doc card at
        // the drop point's world position (crib §6).
        rootView.shelf.onChipClick = { [weak self] path in self?.openPeek(path) }
        rootView.shelf.onChipDropped = { [weak self] path, windowPoint in
            self?.landShelfDrop(path: path, windowPoint: windowPoint)
        }
        // Phase 4 wayfinding: supply the per-card offscreen-hint models (label +
        // priority) the board can't derive on its own (doc metadata / recency).
        // Reads `activeBoard` dynamically, so it tracks the mounted board.
        rootView.offscreenHintProvider = { [weak self] in self?.offscreenHints() ?? [] }
        // Mount board-0 and bind its per-board callbacks (edge labels + layout
        // persistence). The same `mount(_:)` runs on every switch-arrive.
        mount(board0)
    }

    /// Mounts `board`'s view in RootView and (re)binds the controller-owned
    /// per-board callbacks to it: the provenance edge label (crib §8) and the
    /// committed-layout persist. The persist closure captures the board's id (by
    /// value, no retain cycle), so a committed move/resize/zoom/pan persists THAT
    /// board — stamped with its `board_id` — even if a stray callback fires after
    /// it stops being active (it's then dropped by the active-board guard). Called
    /// at boot and on every switch-arrive.
    private func mount(_ board: Board) {
        rootView.mountBoard(board.view)
        board.view.edgeLabelProvider = { [weak self] id in self?.edgeLabel(for: id) }
        let bid = board.boardID
        // TODO(perf): pan fires onLayoutChanged per scroll event — cheap LWW for
        // now; debounce/coalesce the layout send if pan persistence gets chatty.
        board.view.onLayoutChanged = { [weak self] _ in self?.persistLayout(forBoardID: bid) }
    }

    /// Makes the prime terminal the window's first responder (initial focus): the
    /// terminal is the default first responder so typing lands in the shell.
    func focusPrimeTerminal() {
        if let view = primeTerminalView { window?.makeFirstResponder(view) }
    }

    func start() {
        client.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        client.onDisconnect = { [weak self] reason in
            MainActor.assumeIsolated { self?.handleDisconnect(reason) }
        }

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only the four "intent" modifiers. macOS sets .function + .numericPad
            // on arrow keys, so masking with the full .deviceIndependentFlagsMask
            // made `mods == [.control, .command]` impossible for ⌃⌘→ (its raw mods
            // are [.control, .command, .function, .numericPad]) — the cycle key
            // silently never fired. Masking to these four also drops .capsLock,
            // so the no-modifier / single-modifier checks below work with caps on.
            let mods = event.modifierFlags.intersection([.control, .command, .option, .shift])
            let isEsc = event.keyCode == 53
            // Bare Return (no modifiers) toggles the dock / flies; ⌘⏎ is the
            // peek-pin menu key equivalent and is consumed before this monitor.
            let isReturn = event.keyCode == 36 && mods.isEmpty
            // ⌥tab (tab = keyCode 48 with the Option modifier, ignoring caps lock)
            // cycles the focused terminal among terminal cards + shows the HUD
            // (crib §6). With one terminal this is a no-op cycle (single HUD item).
            let isOptTab = event.keyCode == 48 && mods == .option
            // ⌘T (T = keyCode 17) spawns a new terminal card (Phase 5b).
            let isCmdT = event.keyCode == 17 && mods == .command
            // M3 P2 throwaway hotkeys (replaced by the ⌘K switcher in P4):
            // ⌃⌘N (N = 45) creates a board; ⌃⌘→ (Right = 124) switches to the
            // next board. Chosen to not collide with shell or existing bindings.
            let isCtrlCmdN = event.keyCode == 45 && mods == [.control, .command]
            let isCtrlCmdRight = event.keyCode == 124 && mods == [.control, .command]
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                // Every keystroke passes through here before its view handles it,
                // so keep prime in sync with the terminal the user is typing in
                // (clicking a non-prime terminal made it first responder without
                // updating primeTermID). Cheap: only re-styles on an actual change.
                self.reconcilePrimeToFocus()
                if isCmdT {
                    self.spawnNewTerminal()
                    return true
                }
                if isCtrlCmdN {
                    self.client.boardCreate()
                    return true
                }
                if isCtrlCmdRight {
                    self.switchToNextBoard()
                    return true
                }
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
                        self.preFlightViewport = self.activeBoard.view.viewport
                        self.activeBoard.view.fly(to: target)
                        return true
                    }
                    self.toggleDock()
                    return true
                }
                guard isEsc else { return false }
                // An active board drag/resize swallows esc ahead of everything
                // (crib §5 DECISION; was desk.cancelDrag()).
                if self.activeBoard.view.cancelDrag() {
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
                    self.activeBoard.view.flyTo(prev)
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
        case .boardList(let metas, let active):
            boardMetas = metas
            dbg("board_list active=\(active) appActive=\(activeBoardID) switching=\(switching) boards=\(metas.count)")
            // The daemon changed the active board out from under us (board_create
            // auto-activates the new board): follow it — leave the current board
            // so the restore that follows mounts the new one. An app-initiated
            // switch already set activeBoardID = active, so this is a no-op then.
            if active != activeBoardID, !switching {
                beginArrivingSwitch(to: active)
            }
            refreshStrips()
        case .restore(let docs, let tiles, let board, let restoredBoardID):
            applyRestore(docs: docs, tiles: tiles, viewport: board, boardID: restoredBoardID)
        case .output(let termID, let bytes):
            // Route to the owning board's session (which may be backgrounded):
            // feeding a detached SwiftTerm view still advances its buffer, so a
            // background board's shell keeps progressing and shows fresh output
            // on switch-back. Never touches the active view unless it owns the term.
            guard let s = session(ofTerm: termID), s.live else { return }
            s.view.feed(byteArray: [UInt8](bytes)[...])
        case .exit(let termID, let code):
            handleExit(termID: termID, code: code)
        case .docOpened(let doc):
            handleDocOpened(doc)
        case .fileEvent(let path, let mtimeMs):
            // The watcher is global; route the event to every board whose store
            // knows the path (a doc can live on a backgrounded board). Only the
            // active board's card / peek re-renders.
            for board in boards.values where board.store.doc(for: path) != nil {
                board.store.applyFileEvent(path: path, mtimeMs: mtimeMs)
            }
            if isOnBoard(path) {
                activeBoard.view.card(.doc(path))?.renderDoc(markdown: readMarkdown(path))
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

    /// `.doc_opened`: route the doc to the board owning its caller term (the
    /// `tarmac open` that produced it ran with that term's `TARMAC_TERM_ID`),
    /// falling back to the active board for a user open / unknown term. The doc's
    /// state lands in THAT board's store and a `tarmac open` lands a fresh card on
    /// THAT board — so an open from a backgrounded board's shell never lands a
    /// card on the active board (crit S4); read-on-open only applies to the
    /// active board (peek + visible cards are the active board's).
    private func handleDocOpened(_ doc: RestoreDoc) {
        let board = doc.termID.flatMap { ownerBoard(ofTerm: $0) } ?? activeBoard
        let wasOnBoard = board.view.card(.doc(doc.path)) != nil
        board.store.applyDocOpened(doc)
        if let termID = doc.termID { board.docOwner[doc.path] = termID }
        // crib §5 / migration-plan Phase 3: a doc arriving via `tarmac open` lands
        // a FRESH card right of its caller term card (first free slot). A user
        // open keeps prior behavior (no card).
        if doc.via == "cli", !wasOnBoard, !board.shelfPaths.contains(doc.path) {
            landFreshCard(path: doc.path, on: board)
            persistLayout(for: board)
        }
        // Read-on-open applies only when the doc is on / peeked over the ACTIVE
        // board (a brand-new fresh card keeps its unread/fresh ring until touched).
        guard board === activeBoard else { return }
        if (rootView.peekVisible && peekPath == doc.path) || wasOnBoard {
            board.store.markRead(doc.path)
            client.docRead(path: doc.path)
            clearFreshIfRead(doc.path)
            if rootView.peekVisible && peekPath == doc.path {
                refreshPeek(doc.path)
            }
        }
    }

    private func handleDisconnect(_ reason: String) {
        connected = false
        // The connection dropped for every board's ptys, not just the active one.
        for board in boards.values {
            for s in board.sessions.values { s.live = false }
        }
        feedNotice("lost connection to tarmacd — \(reason)")
        rootView.toasts.show(title: "tarmacd connection lost", body: reason)
    }

    private func showConnectFailure(_ detail: String) {
        feedNotice(detail)
        rootView.toasts.show(title: "cannot reach tarmacd", body: "see terminal for details")
    }

    // M3 (throwaway ⌃⌘→ until the P4 ⌘K switcher): switch to the next board in
    // display order (wrapping).
    private func switchToNextBoard() {
        guard let next = BoardRegistry.nextBoardID(after: activeBoardID, in: boardMetas) else {
            feedNotice("only one board — ⌃⌘N creates another")
            return
        }
        performSwitch(to: next)
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
    private func beginArrivingSwitch(to targetID: String) {
        guard let meta = boardMetas.first(where: { $0.boardID == targetID }) else {
            dbg("beginArrivingSwitch DROPPED — \(targetID) not in boardMetas")
            return
        }
        dbg("beginArrivingSwitch → \(targetID) (minted=\(boards[targetID] != nil))")
        switching = true
        // Keep prime synced to the terminal the user last typed in, then pull
        // first responder OFF the leaving board's views before the view is
        // swapped — a stale responder would leave the arrived board unfocused
        // (boardHasFocus false until a click). Target nil, not rootView.board,
        // which is about to be swapped (crit B3).
        reconcilePrimeToFocus()
        if activeBoard.docked { undockForLeave() }
        window?.makeFirstResponder(nil)
        rootView.unmountBoard()
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

    /// Undocks the leaving board's terminal on switch-away: reparent the docked
    /// SwiftTerm view back into its card and hide the shared pane, WITHOUT
    /// fly-back and WITHOUT a reflow/resize — the card is about to be detached,
    /// so reflowing now would resize the pty to a doomed geometry (crit B2). The
    /// board's `docked` intent is kept so switch-back re-docks.
    private func undockForLeave() {
        guard activeBoard.docked, let view = activeBoard.primeTerminalView else { return }
        view.removeFromSuperview()
        activeBoard.primeTermCard?.attachTerminal(view)
        rootView.setDockVisible(false)
        activeBoard.view.setDocked(nil)
        // NB: activeBoard.docked stays true (intent); finishArrive re-docks.
    }

    /// The ARRIVE half: the target's view is mounted and (on a first visit) its
    /// cards/terminals built; now re-establish focus + dock on the arrived board,
    /// AFTER its card tree is laid out (crit B3 / S1), and end the transient.
    private func finishArrive(on board: Board) {
        rootView.layoutSubtreeIfNeeded()
        // Re-dock only when there is a LIVE prime to dock; dock() itself guards on
        // hasLivePrime, so gating here keeps the focus fallback reachable. Drop a
        // stale dock intent for a board whose docked terminal died while
        // backgrounded (its undock was isActive-gated, so docked stayed true) —
        // otherwise focus, cleared to nil on leave, is never re-established.
        if board.docked, board.hasLivePrime {
            // Re-dock: reparent the prime terminal into the shared pane (dock()
            // guards on !docked, reflows, and makes the view first responder).
            board.docked = false
            dock()
        } else {
            board.docked = false
            if let view = board.primeTerminalView {
                window?.makeFirstResponder(view)
            } else {
                window?.makeFirstResponder(rootView.board)
            }
        }
        updatePrimacy()
        switching = false
        dbg("finishArrive done board=\(board.boardID) prime=\(board.primeTermID ?? "nil") mounted=\(rootView.board === board.view)")
    }

    // MARK: - Terminal session

    /// Builds a configured terminal session (SwiftTerm view + a delegate bridge
    /// carrying its `term_id`). The view is not yet on the board or spawned.
    private func makeSession(termID: String) -> TerminalSession {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.font = Theme.mono(12)
        view.nativeBackgroundColor = Theme.termBg
        view.nativeForegroundColor = Theme.termFg
        view.caretColor = Theme.text
        view.optionAsMetaKey = true
        let bridge = TermDelegateBridge(termID: termID)
        bridge.controller = self
        view.terminalDelegate = bridge
        return TerminalSession(termID: termID, view: view, bridge: bridge)
    }

    /// Reconciles `primeTermID` to whichever LIVE terminal currently holds the
    /// window's keyboard focus — e.g. the user clicked a non-prime terminal,
    /// which AppKit made first responder (typing already routes there via its
    /// bridge). Called before any action that re-asserts focus to the prime
    /// terminal (peek / dock / cycle), so focus is never yanked back to a stale
    /// prime. No-op when the focused responder isn't a live terminal view.
    private func reconcilePrimeToFocus() {
        guard let responder = window?.firstResponder as? NSView else { return }
        for (id, s) in sessions where s.live {
            if responder === s.view || responder.isDescendant(of: s.view) {
                if id != primeTermID {
                    primeTermID = id
                    updatePrimacy()
                }
                return
            }
        }
    }

    func terminalSizeChanged(termID: String, cols: Int, rows: Int) {
        viewReady = true
        maybeSpawn()
        guard let s = sessions[termID], s.live, cols > 0, rows > 0,
              cols != s.lastSentCols || rows != s.lastSentRows else { return }
        s.lastSentCols = cols
        s.lastSentRows = rows
        client.resize(termID: termID, cols: cols, rows: rows)
    }

    func terminalDidSend(termID: String, _ bytes: Data) {
        guard let s = sessions[termID], s.live else { return }
        // A keystroke clears this terminal's amber bell signal (M2).
        activeBoard.view.card(.term(termID))?.setBell(false)
        activeBoard.view.signalsChanged()
        client.input(termID: termID, bytes: bytes)
    }

    /// Ensures the prime terminal is spawned (the boot terminal on a cold start).
    /// Further terminals are spawned by ⌘T (`spawnNewTerminal`) and by restore
    /// (`restoreTerminals`).
    private func maybeSpawn() {
        guard connected, viewReady, let s = primeSession, !s.live else { return }
        spawn(session: s)
    }

    /// Spawns a pty for `session` and seeds its card label / live state.
    private func spawn(session s: TerminalSession) {
        let term = s.view.getTerminal()
        let cols = max(2, term.cols)
        let rows = max(2, term.rows)
        s.live = true
        s.lastSentCols = cols
        s.lastSentRows = rows
        client.spawnTerm(termID: s.termID, cols: cols, rows: rows, cwd: NSHomeDirectory(), cmd: nil)
        // cmd nil ⇒ the daemon spawns $SHELL (else /bin/zsh); mirror that
        // resolution for the card label — a fact known at spawn time.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        s.label = (shell as NSString).lastPathComponent
        s.shellName = s.label
        s.liveProcSince = nil
        activeBoard.view.card(.term(s.termID))?.setTermLabel(s.label)
        activeBoard.view.card(.term(s.termID))?.setLive(false)
        refreshTermLocard(s.termID)
        // Cards restored before the term spawned get their gravity owner +
        // chip resolved now.
        rebindOwners()
        // The term card is now prime (focused terminal); doc cards go quiet.
        updatePrimacy()
    }

    /// ⌘T: spawns a new terminal card cascade-offset from the prime card (crib
    /// §6 decision 3), makes it prime + first responder, and persists it.
    private func spawnNewTerminal() {
        guard connected, viewReady else { return }
        // Land the new terminal on the board, not behind the dock pane: undock
        // the current terminal first so focus + the dock stay coherent.
        if docked { undock() }
        let id = BootTerminal.mint()
        let session = makeSession(termID: id)
        sessions[id] = session
        sessionOrder.append(id)
        termIndex.assign(termID: id, to: activeBoardID)
        activeBoard.view.setTerminal(termID: id, session.view, worldFrame: cascadeFrame())
        // Lay out so the terminal view has its card-sized geometry before spawn,
        // so the pty starts at the right cols/rows (not the 800×600 default).
        rootView.layoutSubtreeIfNeeded()
        // The new terminal becomes prime + first responder (typing follows it).
        primeTermID = id
        spawn(session: session)
        activeBoard.view.select(.term(id))
        if !docked { window?.makeFirstResponder(session.view) }
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

    private func handleExit(termID: String, code: Int?) {
        // Resolve the OWNING board (the exit may be on a backgrounded board):
        // the dead card / prime advance happen on that board, not the active one.
        guard let board = ownerBoard(ofTerm: termID), let s = board.sessions[termID], s.live else { return }
        s.live = false
        termIndex.remove(termID: termID)
        let isActive = board === activeBoard
        let card = board.view.card(.term(termID))
        // A dead terminal can't ring: clear any lingering bell, then put the card
        // into its dead `exit N · respawn` state (decision 1: no auto-respawn —
        // the card stays on the board at its frame; respawn-in-place is post-5b).
        card?.setBell(false)
        card?.setDead(code)
        board.view.signalsChanged()
        // If the dying terminal was docked on the ACTIVE board, return its
        // (now-dead) view to its card and hide the dock before prime advances, so
        // the dock never holds a view that is no longer prime (risk: off-screen
        // input routing). The dock pane is the active board's; a backgrounded
        // board is never docked-into-the-pane (it was undocked on switch-away).
        if isActive, board.docked, board.primeTermID == termID {
            undock()
        }
        // Advance THIS board's prime past the dead terminal (refocus only when
        // it is the active board the user is looking at).
        advancePrime(on: board, after: termID)
        let label = code.map { "exit \($0)" } ?? "killed by signal"
        feedNotice("shell exited (\(label))", to: s)
        // Exit toast (M2 honest signals): title "shell exited · <code>" (or
        // "killed by signal" when code is nil).
        let toastTitle = code.map { "shell exited · \($0)" } ?? "killed by signal"
        rootView.toasts.show(icon: "›_", title: toastTitle, body: nil)
        // Persist so the card's position survives a restart (it respawns fresh
        // into that slot per decision 2). A backgrounded board's frame is
        // unchanged by the exit (already persisted), so only the active board
        // re-persists here; the switch path persists per board.
        if isActive { persistLayout() }
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
                    if isActive, !board.docked { window?.makeFirstResponder(board.sessions[id]?.view) }
                    return
                }
            }
        }
        // No live terminal remains on this board: nothing is prime. On the active
        // board, move first responder off the dead terminal view to the board so
        // Return/dock/fly stay reachable (boardHasFocus would otherwise never be
        // true again until a board click).
        board.primeTermID = nil
        if isActive { window?.makeFirstResponder(rootView.board) }
        updatePrimacy(on: board)
    }

    /// Feeds a dim notice line into a terminal's scrollback — the given session,
    /// or the prime terminal when no session is named (e.g. a connect failure).
    private func feedNotice(_ text: String, to session: TerminalSession? = nil) {
        (session?.view ?? primeTerminalView)?.feed(text: "\r\n\u{1b}[2m· \(text)\u{1b}[0m\r\n")
    }

    // MARK: - M2 honest signals (Phase 3.5)

    /// `.termProc`: the honest "card title = process name" — set the term card's
    /// header label to the foreground process name, replacing the shell basename
    /// set at spawn. The owner chips (`← <termname>`) follow the same label so
    /// they stay honest too.
    private func handleTermProc(termID: String, name: String) {
        // Resolve the owning board (the proc may be on a backgrounded board); its
        // detached card state must stay honest because a re-visit re-mounts the
        // view rather than rebuilding it.
        guard let board = ownerBoard(ofTerm: termID), let s = board.sessions[termID], s.live else { return }
        let isActive = board === activeBoard
        s.label = name
        board.view.card(.term(termID))?.setTermLabel(name)
        // Keep the dock header label honest while docked, but only for the docked
        // (prime) terminal on the ACTIVE board (the dock pane is the active board's).
        if isActive, board.docked, termID == board.primeTermID {
            rootView.dockPane.setTermLabel(name.isEmpty ? "shell" : name)
        }
        // "Live" (agent-active) when the foreground process is no longer the bare
        // shell (crib §6: cyan = agent-active). The honest signal we have at this
        // phase is the foreground process name; treat shell == idle.
        let live = !name.isEmpty && name != s.shellName
        let card = board.view.card(.term(termID))
        let wasLive = card?.liveActive ?? false
        if live, !wasLive { s.liveProcSince = Date() }
        if !live { s.liveProcSince = nil }
        card?.setLive(live)
        board.view.signalsChanged()
        refreshTermLocard(termID, on: board)
        // Re-render this board's attached doc cards' owner chips with the new name.
        for path in board.boardDocPaths {
            guard let docCard = board.view.card(.doc(path)) else { continue }
            docCard.setOwnerChip(ownerChipLabel(for: docCard, on: board))
        }
    }

    // MARK: - Phase 4 wayfinding (locard content, offscreen hints)

    /// Feeds a terminal card's locard content (crib §7): the foreground process
    /// name + a duration (`<proc> · Ns`) when live, else the shell name idle.
    private func refreshTermLocard(_ termID: String, on board: Board? = nil) {
        let b = board ?? activeBoard
        guard let s = b.sessions[termID], let card = b.view.card(.term(termID)) else { return }
        let status: String
        if card.liveActive, let since = s.liveProcSince {
            let secs = max(1, Int(Date().timeIntervalSince(since).rounded()))
            status = "running · \(secs)s"
        } else {
            status = "idle"
        }
        card.setLocardContent(name: s.label.isEmpty ? "shell" : s.label, status: status, repoColor: nil)
    }

    /// Feeds a doc card's locard content (crib §7): basename + recency line.
    private func refreshDocLocard(_ path: String, on board: Board? = nil) {
        let b = board ?? activeBoard
        guard let card = b.view.card(.doc(path)), let doc = b.store.doc(for: path) else { return }
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

    /// True when keyboard focus is on the board rather than the terminal — so a
    /// bare Return triggers the offscreen flight instead of the shell's Enter
    /// (crib §6 focus model). The terminal is the default first responder; the
    /// board takes focus only when the user clicks its background.
    private func boardHasFocus() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        // Any terminal view (or a descendant) holding focus means a terminal —
        // not the board — is focused, so Return belongs to the shell.
        for s in sessions.values {
            if responder === s.view { return false }
            if let view = responder as? NSView, view.isDescendant(of: s.view) { return false }
        }
        // The board view itself (or a non-terminal board descendant) is focused.
        if let view = responder as? NSView, view.isDescendant(of: rootView.board) { return true }
        return responder === rootView.board
    }

    // MARK: - Terminal primacy: prime / quiet focus model (Phase 5a, crib §4)

    /// Applies the prime/quiet card states (crib §4): the prime terminal card
    /// (focused terminal: `#5a626a` border, `#3a4046` header, deeper shadow) is
    /// raised and every other card — docs and non-prime terminals — is quiet
    /// (opacity 0.8). Prime follows the ⌥tab cycle / ⌘T (Phase 5b); a dead
    /// terminal card keeps its own dim and never reads as prime. Nothing is prime
    /// when no terminal is live.
    private func updatePrimacy(on board: Board? = nil) {
        let b = board ?? activeBoard
        let primeID: CardID? = b.hasLivePrime ? b.primeTermID.map(CardID.term) : nil
        for (id, card) in b.view.cards {
            let isPrime = (id == primeID)
            card.setPrime(isPrime)
            // A card is quiet only while some terminal is prime and it isn't it.
            card.setQuiet(primeID != nil && !isPrime)
        }
    }

    /// Makes `termID` the prime (focused) terminal: re-applies primacy styling
    /// and moves keyboard first responder to its view (unless docked). Typing
    /// always follows the prime terminal regardless of pointer (crib §6). Used by
    /// ⌥tab and ⌘T.
    private func setPrime(_ termID: String) {
        guard let s = sessions[termID] else { return }
        primeTermID = termID
        updatePrimacy()
        if !docked { window?.makeFirstResponder(s.view) }
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
        guard !docked, hasLivePrime, let id = primeTermID, let view = primeTerminalView else { return }
        docked = true
        // Reparent the prime SwiftTerm view: card body → dock pane body.
        view.removeFromSuperview()
        rootView.dockPane.body.addSubview(view)
        let label = primeSession?.label ?? ""
        rootView.dockPane.setTermLabel(label.isEmpty ? "shell" : label)
        rootView.setDockVisible(true)
        activeBoard.view.setDocked(.term(id))
        // Reflow into the dock body's geometry, then restore first responder so
        // keystrokes still land in the terminal (the delegate is unchanged).
        // Lay out RootView first so the dock pane has its (just-shown) frame,
        // then the pane subtree positions the reparented terminal.
        rootView.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(view)
        forceTerminalReflow()
        updatePrimacy()
    }

    /// Returns the docked terminal to its board card (crib §4): REPARENT the
    /// SwiftTerm view dock pane body → card body, hide the dock pane + slot ghost,
    /// reflow + restore first responder.
    private func undock() {
        guard docked else { return }
        docked = false
        if let view = primeTerminalView {
            view.removeFromSuperview()
            primeTermCard?.attachTerminal(view)
        }
        rootView.setDockVisible(false)
        activeBoard.view.setDocked(nil)
        // Reflow into the card body's geometry, then restore first responder.
        rootView.layoutSubtreeIfNeeded()
        if let view = primeTerminalView { window?.makeFirstResponder(view) }
        forceTerminalReflow()
        updatePrimacy()
    }

    /// Nudges the prime terminal to re-measure its cols/rows after a reparent so
    /// the daemon pty resizes to the new geometry. SwiftTerm reflows on a frame
    /// change; `terminalSizeChanged` then forwards the resize to the daemon.
    private func forceTerminalReflow() {
        guard let id = primeTermID, let view = primeTerminalView else { return }
        // A layout pass already ran; re-assert the current size to the daemon in
        // case the cols/rows are unchanged but the view was reparented.
        let term = view.getTerminal()
        terminalSizeChanged(termID: id, cols: term.cols, rows: term.rows)
    }

    // MARK: - ⌥tab terminal cycle + HUD (Phase 5a scaffold, crib §6)

    /// ⌥tab advances the prime (focused) terminal to the next LIVE terminal card
    /// in spawn order (wrapping) and flashes the cycle HUD with every live
    /// terminal's label, the new prime highlighted (crib §6). Dead terminals are
    /// skipped. With one terminal this re-asserts focus (a single-item HUD).
    private func cycleTerminals() {
        // Cycling while docked would desync the dock (which holds one terminal's
        // view) from prime; esc to undock first.
        guard !docked else { return }
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
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date())
    }

    /// `.bell`: a BEL was seen on the terminal — give its card the amber bell
    /// signal. Cleared on the next keystroke to that terminal or on focus
    /// (see `terminalDidSend` / `clearBell`).
    private func handleBell(termID: String) {
        // Route to the owning board (a backgrounded board can ring); its detached
        // card lights amber and shows the signal on switch-back.
        guard let board = ownerBoard(ofTerm: termID), board.sessions[termID]?.live == true else { return }
        board.view.card(.term(termID))?.setBell(true)
        board.view.signalsChanged()
    }

    /// Clears the amber bell signal on the term card (next keystroke / focus).
    private func clearBell() {
        primeTermCard?.setBell(false)
        activeBoard.view.signalsChanged()
    }

    // MARK: - Board layout (restore + persistence)

    /// Applies a daemon `restore` to the board it is stamped for. The daemon
    /// sends a restore only for its active board, and the `board_list` that sets
    /// `activeBoardID` always precedes it, so the restore's `board_id` matches
    /// the active board; a restore for any other board is stale (it arrived after
    /// a later switch) and is dropped (restore-ordering guard). A board that has
    /// already taken its first restore is not rebuilt — that would tear down its
    /// doc cards and respawn its live terminals; the switch path re-mounts the
    /// existing view instead (Step 9). `board_id` absent ⇒ board-0 (legacy).
    private func applyRestore(docs: [RestoreDoc], tiles: [LayoutTile], viewport: BoardViewport?, boardID: String?) {
        let targetID = boardID ?? Board.defaultID
        guard targetID == activeBoardID, let board = boards[targetID] else {
            dbg("restore DROPPED — target=\(boardID ?? "nil→board-0") appActive=\(activeBoardID) minted=\(boards[boardID ?? Board.defaultID] != nil) switching=\(switching)")
            return
        }
        dbg("restore apply target=\(targetID) switching=\(switching) firstRestore=\(!board.didInitialRestore) tiles=\(tiles.count)")
        // On a switch-arrive, mount the target's view (boot already mounted
        // board-0). A re-visit still mounts + refocuses below — only the rebuild
        // is gated on the first restore.
        if switching { mount(board) }
        // Build the board's cards/terminals on its FIRST restore only; a re-visit
        // keeps its live view as-is (a rebuild would respawn its terminals).
        if !board.didInitialRestore {
            board.didInitialRestore = true
            board.store.applyRestore(docs)
            // Seed provenance from the restored doc entries (term_id owner).
            for doc in docs {
                if let termID = doc.termID { board.docOwner[doc.path] = termID }
            }
            applyRestoredLayout(tiles: tiles, board: viewport)
            // Boot-spawn triggers (helloOK / initial viewReady) fire once per
            // launch; a switch-arrival must drive the arriving board's prime
            // spawn itself (crit S1). Lay the just-mounted view out first so the
            // boot pty starts at the card size, not the 800×600 view default.
            rootView.layoutSubtreeIfNeeded()
            maybeSpawn()
        }
        refreshStrips()
        if switching { finishArrive(on: board) }
    }

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
        for id in Array(activeBoard.view.cards.keys) {
            if case .doc = id { activeBoard.view.removeCard(id: id) }
        }
        shelfPaths = []

        let termTiles = tiles.filter { $0.kind == "term" }
        let docTiles = tiles.filter { $0.kind == "doc" }
        var migratedAny = termTiles.contains { CardFrame(tile: $0) == nil }

        // Restore N terminal cards (decision 2: positions persist, fresh shells
        // respawn) and re-anchor doc provenance across the restart (best-effort).
        let oldToNew = restoreTerminals(termTiles)
        remapDocOwners(oldToNew, restoredTerminalCount: termTiles.count)

        var docSlot = 0
        for tile in docTiles {
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

    /// Restores terminal cards from `termTiles` (decision 2: positions persist,
    /// fresh shells respawn — live-session restore is M3). The boot session/card
    /// is reused for the first tile (its fresh shell is spawned by `maybeSpawn`);
    /// each additional tile gets a fresh session + card + pty. Returns the
    /// persisted→reborn `term_id` remap so doc provenance can re-anchor.
    @discardableResult
    private func restoreTerminals(_ termTiles: [LayoutTile]) -> [String: String] {
        var oldToNew: [String: String] = [:]
        guard let bootID = primeTermID else { return oldToNew }
        for (i, tile) in termTiles.enumerated() {
            let frame = CardFrame(tile: tile) ?? Place.termFrame
            let newID: String
            if i == 0 {
                // Reuse the boot session/card (created at init, kept prime).
                newID = bootID
                if let view = primeTerminalView {
                    activeBoard.view.setTerminal(termID: bootID, view, worldFrame: frame)
                }
            } else {
                // A fresh session + card + pty for each additional terminal.
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

    /// Adds (or replaces) a doc card, renders its content, and seeds gravity:
    /// ownerTermID from the doc's provenance + the attached flag (owner chip
    /// shown while attached). `fresh` gives the just-spawned ring + `✚ now`.
    @discardableResult
    private func landDocCard(path: String, frame: CardFrame, attached: Bool, fresh: Bool, on board: Board? = nil) -> CardView {
        let b = board ?? activeBoard
        let card = b.view.addCard(id: .doc(path), worldFrame: frame)
        if let doc = b.store.doc(for: path) { card.apply(doc: doc) }
        card.ownerTermID = ownerCardID(for: path, on: b)
        card.attached = attached && card.ownerTermID != nil
        if fresh { card.setFresh(true) }
        card.setOwnerChip(ownerChipLabel(for: card, on: b))
        card.renderDoc(markdown: readMarkdown(path))
        refreshDocLocard(path, on: b)
        b.view.recomputeEdges()
        // A doc card is quiet while a terminal is prime (crib §4).
        if b.hasLivePrime { card.setQuiet(true) }
        return card
    }

    /// The board CardID of a doc's provenance owner term card, when resolvable
    /// (Phase 5b): the doc binds to *its* terminal — the `term_id` that opened it
    /// — not "the" terminal. Returns nil (doc stays loose) when that terminal no
    /// longer exists (e.g. a genuinely-orphaned owner after a restart remap).
    private func ownerCardID(for path: String, on board: Board? = nil) -> CardID? {
        let b = board ?? activeBoard
        // The pure resolution (owner recorded + still one of this board's live
        // terminals) lives in TarmacKit; map it to a card after confirming the
        // term card exists on the board.
        guard let tid = DocRouting.resolveOwner(
            path: path,
            owners: b.docOwner,
            liveTermIDs: Set(b.sessions.keys)
        ), b.view.card(.term(tid)) != nil else {
            return nil
        }
        return .term(tid)
    }

    /// `← <termname>` chip text for an attached doc card, else nil — the label of
    /// the doc's owner terminal (Phase 5b: its own terminal, not "the" terminal).
    private func ownerChipLabel(for card: CardView, on board: Board? = nil) -> String? {
        let b = board ?? activeBoard
        guard card.attached, case .term(let ownerID)? = card.ownerTermID else { return nil }
        let label = b.sessions[ownerID]?.label ?? ""
        return label.isEmpty ? nil : label
    }

    /// Re-resolves any still-unbound doc-card owners and refreshes the owner chips
    /// with the now-known term label. `landDocCard` already resolves owners at
    /// restore (the term card exists from init, so `ownerCardID` resolves), making
    /// this mostly a chip refresh; it also covers the ordering where a card was
    /// restored attached before its owner was resolvable. A detached card stays
    /// detached. Called from maybeSpawn.
    private func rebindOwners() {
        for path in boardDocPaths {
            guard let card = activeBoard.view.card(.doc(path)) else { continue }
            if card.ownerTermID == nil, card.attached {
                card.ownerTermID = ownerCardID(for: path)
            }
            card.setOwnerChip(ownerChipLabel(for: card))
        }
        activeBoard.view.recomputeEdges()
    }

    // MARK: - Fresh card landing (crib §5)
    //
    // `freshCardPath` (the most-recent fresh card; esc → shelf) is board-scoped
    // and lives on `Board`, reached here via the active-board shim.

    /// Lands a fresh doc card to the right of its CALLER term card (the terminal
    /// that ran `tarmac open`, not necessarily the prime one) via a first-free-
    /// slot search; gives it the fresh ring + `✚ now` meta.
    private func landFreshCard(path: String, on board: Board? = nil) {
        let b = board ?? activeBoard
        let caller = ownerCardID(for: path, on: b).flatMap { b.view.card($0) }
        let frame = firstFreeSlot(near: caller, on: b)
        landDocCard(path: path, frame: frame, attached: true, fresh: true, on: b)
        b.freshCardPath = path
    }

    /// First-free-slot search (crib §5): start at the anchor term card's right
    /// edge + ~gapX (the caller terminal, or the prime terminal when no anchor),
    /// find a docW×docH world rect not overlapping existing cards, scanning right
    /// then down.
    private func firstFreeSlot(near anchorCard: CardView? = nil, on board: Board? = nil) -> CardFrame {
        let b = board ?? activeBoard
        let term = (anchorCard ?? b.primeTermCard)?.worldFrame ?? Place.termFrame
        let startX = term.x + term.w + Place.gapX
        let startY = term.y
        let stepX = Place.docW + Place.gapX
        let stepY = Place.docH + Place.gapY
        let existing = b.view.cards.values.map(\.worldFrame.rect)
        let topZ = (b.view.cards.values.map(\.worldFrame.z).max() ?? 0) + 1
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
        guard let card = activeBoard.view.card(.doc(path)), card.fresh else { return }
        card.setFresh(false)
        if freshCardPath == path { freshCardPath = nil }
    }

    /// esc sends a still-fresh card to the shelf (crib §5): set its tile
    /// shelf:true, remove the board card, persist. Returns false when there is
    /// no fresh card so esc falls through to peek/toast dismissal.
    @discardableResult
    private func sendFreshCardToShelf() -> Bool {
        guard let path = freshCardPath, let card = activeBoard.view.card(.doc(path)), card.fresh else {
            freshCardPath = nil
            return false
        }
        freshCardPath = nil
        moveToShelf(path)
        return true
    }

    /// Moves a doc from the board to the shelf, persists, refreshes.
    private func moveToShelf(_ path: String) {
        activeBoard.view.removeCard(id: .doc(path))
        if !shelfPaths.contains(path) { shelfPaths.append(path) }
        persistLayout()
        refreshStrips()
    }

    /// Lands a shelf chip dragged onto the board at the drop point's world
    /// position (crib §6). Removes it from the shelf and persists.
    private func landShelfDrop(path: String, windowPoint: NSPoint) {
        guard store.doc(for: path) != nil else { return }
        shelfPaths.removeAll { $0 == path }
        let viewPoint = activeBoard.view.convert(windowPoint, from: nil)
        let world = activeBoard.view.viewToWorld(viewPoint)
        let topZ = (activeBoard.view.cards.values.map(\.worldFrame.z).max() ?? 0) + 1
        // Drop point is the card's top-left.
        let frame = CardFrame(x: world.x, y: world.y, w: Place.docW, h: Place.docH, z: topZ)
        // A shelf doc lands detached (it had no board placement / gravity tie).
        landDocCard(path: path, frame: frame, attached: false, fresh: false)
        persistLayout()
        refreshStrips()
    }


    private func isOnBoard(_ path: String) -> Bool {
        activeBoard.view.card(.doc(path)) != nil
    }

    /// Reports the full layout snapshot (docs/protocol.md `layout`;
    /// last-writer-wins): each terminal card's frame + its `term_id` (Phase 5b:
    /// N terminal cards, live AND dead, persist distinct positions), each board
    /// doc card's frame with its `loose` flag (shelf:false), and each shelf doc
    /// as a geometry-less `shelf:true` tile. Plus the board viewport `{zoom,cx,
    /// cy}`. Fired on every committed board move/resize/zoom/pan, and on
    /// shelf/gravity changes.
    private func persistLayout() {
        persistLayout(for: activeBoard)
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
    private func persistLayout(for board: Board) {
        // Drop everything during a switch transient (undock / unmount / re-mount /
        // rebuild fire layout passes whose geometry is mid-flight) and any
        // callback from a non-active board (input/gestures reach no detached view).
        guard !switching, board === activeBoard else { return }
        var tiles: [LayoutTile] = []
        // Every terminal card (in spawn order, live and dead) with its term_id —
        // the daemon dedups by term_id and keeps all distinct positions.
        for tid in board.sessionOrder {
            guard let card = board.view.card(.term(tid)) else { continue }
            tiles.append(boardTile(kind: "term", path: nil, termID: tid, card: card))
        }
        for path in board.boardDocPaths.sorted() {
            guard let card = board.view.card(.doc(path)) else { continue }
            tiles.append(boardTile(kind: "doc", path: path, card: card))
        }
        // Shelf docs: kind "doc", shelf:true, loose:true, no geometry (crib §6).
        for path in board.shelfPaths {
            tiles.append(LayoutTile(kind: "doc", path: path, loose: true, shelf: true))
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
            shelf: kind == "doc" ? false : nil,
            termID: termID
        )
    }

    // MARK: - Docs / peek

    private var peekPath: String? { rootView.peek.currentPath }

    /// Wires a board's doc store to refresh the chrome on change — but only while
    /// that board is active (a backgrounded board's store can mutate via a
    /// cross-board file event, which must not refresh the active chrome).
    private func wireStore(_ board: Board) {
        let bid = board.boardID
        board.store.onChange = { [weak self] in self?.storeChanged(onBoardID: bid) }
    }

    private func storeChanged(onBoardID bid: String) {
        guard let board = boards[bid] else { return }
        // Drop shelf entries for docs the board's registry no longer knows.
        board.shelfPaths.removeAll { board.store.doc(for: $0) == nil }
        if bid == activeBoardID { refreshStrips() }
    }

    /// Rebuilds the shelf chips, syncs on-board card headers (incl. owner chips)
    /// with the registry, and updates the status-bar counts + cold-start hint.
    private func refreshStrips() {
        rootView.shelf.update(items: shelfPaths.compactMap(shelfItem(for:)))
        for path in boardDocPaths {
            guard let card = activeBoard.view.card(.doc(path)) else { continue }
            if let doc = store.doc(for: path) { card.apply(doc: doc) }
            card.setOwnerChip(ownerChipLabel(for: card))
            refreshDocLocard(path)
        }
        rootView.statusBar.setCounts(board: boardDocPaths.count, shelf: shelfPaths.count)
        // M3: show which board is active + how many exist (a switch is otherwise
        // invisible until P4's titlebar chip / ⌘K switcher).
        let count = max(boardMetas.count, boards.count)
        rootView.statusBar.setBoard(activeBoard.name ?? activeBoardID, count: count)
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
        // A peek (⌘P / shelf click) keeps focus on the terminal it was opened
        // over — reconcile so that's the focused terminal, not a stale prime.
        reconcilePrimeToFocus()
        rootView.peek.present(path: path, doc: store.doc(for: path), markdown: readMarkdown(path))
        rootView.setPeekVisible(true)
        // Presentation marks read; doc_read is idempotent and sent every time.
        store.markRead(path)
        client.docRead(path: path)
        clearFreshIfRead(path)
        refreshStrips()
        // Focus rule: opening a peek never moves keyboard focus off the terminal.
        if let view = primeTerminalView { window?.makeFirstResponder(view) }
    }

    func hidePeek() {
        rootView.setPeekVisible(false)
        refreshStrips()
        if let view = primeTerminalView { window?.makeFirstResponder(view) }
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
            activeBoard.view.removeCard(id: .doc(path))
        } else {
            shelfPaths.removeAll { $0 == path }
            // Land at the gravity position beside the doc's owner terminal (the
            // caller), falling back to the prime terminal; attach when the doc
            // has a resolvable owner so it follows that card + shows the chip.
            let owner = ownerCardID(for: path)
            let ownerCard = owner.flatMap { activeBoard.view.card($0) }
            landDocCard(path: path, frame: firstFreeSlot(near: ownerCard), attached: owner != nil, fresh: false)
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
