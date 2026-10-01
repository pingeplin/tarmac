import AppKit
import TarmacKit
import TarmacTerm

/// One terminal card's state (the board holds N of these): the terminal view
/// and what the app knows about the PTY behind it. Whether the card is dead
/// lives on the board card (`CardView.dead`), not here.
@MainActor
final class TerminalSession {
    let termID: String
    /// Replaced when replayed history has to take the place of what the card
    /// already shows (`AppController.blank`).
    private(set) var view: TerminalView
    /// The card stands for a shell that is running or about to be spawned: true
    /// from the card's creation until its exit is seen or the daemon stops
    /// listing it. The placeholder a board shows before its first restore is
    /// never live.
    var live = false
    /// The card's `spawn_term` has not been sent yet.
    var needsSpawn = false
    /// ⌘T: the terminal whose current directory the spawn inherits.
    var inheritCwdFrom: String?
    /// Header label; see `TermLabel`.
    var label = TermLabel.initial
    /// The daemon's last `term_proc` name, verbatim — `label` loses it to a
    /// later OSC title. Dropped at exit.
    var procName: String?
    /// When the lit bell rang.
    var bellAt: Date?
    /// The grid last sent to the daemon; nil until a spawn or resize went out.
    var sentGrid: TermGrid.Size?
    /// Whether `view` has been fed anything.
    private(set) var hasOutput = false

    /// The PTY exists daemon-side as far as the app knows, so input and
    /// resizes may be sent for it.
    var reachable: Bool { live && !needsSpawn }

    init(termID: String, view: TerminalView) {
        self.termID = termID
        self.view = view
    }

    func feed(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        hasOutput = true
        view.feed(bytes)
    }

    func replaceView(_ fresh: TerminalView) {
        view = fresh
        hasOutput = false
    }
}

@MainActor
final class AppController {
    let client: DaemonClient
    let rootView: RootView
    weak var window: NSWindow?

    var connected = false
    var viewReady = false

    // MARK: - P5.3 bounded auto-reconnect
    //
    // On a dropped daemon connection the app flips the chip/status faint and
    // retries `connect()` on the bounded `Reconnect` backoff. Cards are left as
    // they are; the reconnect's `restore` reconciles them against `live_terms`.
    /// Attempts made since the link last dropped (reset to 0 on `hello_ok`).
    var reconnectAttempt = 0
    /// A `connect()` is in flight on the background queue — guards double-connect.
    var reconnecting = false
    /// App teardown began — gates the scheduler so a pending backoff is a no-op.
    var quitting = false

    var daemonSession = DaemonSession()
    /// The version pair of a stale daemon this app replaced, for the first-visit
    /// restart toast (`RestartNotice`). Set by whoever performs that restart.
    var daemonReplaced: RestartNotice.Replacement?

    lazy var scrollback = ScrollbackRestore(
        request: { [weak self] termID in self?.client.scrollbackRequest(termID: termID) },
        deliver: { [weak self] termID, release in self?.showOutput(termID: termID, release) }
    )
    lazy var layoutPersister = LayoutPersister { [weak self] boardID in self?.sendLayout(boardID: boardID) }

    var escMonitor: Any?
    /// Single-click-to-focus (point 3) + gesture routing (point 2) live in
    /// local event monitors armed in `start()` and torn down in `shutdown()`.
    var clickFocusMonitor: Any?
    var scrollRouteMonitor: Any?
    var magnifyRouteMonitor: Any?
    /// Flushes a click-focus restack that was deferred while the button was held,
    /// so a terminal selection drag isn't severed mid-track (see `raiseToFront`).
    var mouseUpRestackMonitor: Any?

    /// The card the user last clicked into. nil ⇒ board-navigation mode: pan,
    /// pinch-zoom, and scroll drive the whiteboard even when the pointer is over a
    /// card (point 2). A click on a card sets it (a live terminal also becomes
    /// prime); a click on the empty board clears it. While set, scroll over *that*
    /// card routes to its own content (terminal scrollback / doc scroll) instead.
    var focusedCardID: CardID?

    // MARK: - Boards (M3 P3)
    //
    // The app holds N boards keyed by `board_id`; `activeBoard` is the one the
    // user is looking at (its `view` is the mounted BoardView). The board-scoped
    // state — sessions, prime, provenance, restore latch — lives on `Board`; the
    // shims below delegate to whichever board is active, so an unqualified
    // read/write always targets the board on screen.
    var boards: [String: Board] = [:]
    var activeBoardID = Board.defaultID
    /// The active board. Force-unwrapped: `boards` always contains
    /// `activeBoardID` (the invariant the boot path + the switch path maintain).
    var activeBoard: Board { boards[activeBoardID]! }

    /// term_id → board_id ownership index (set at spawn, cleared at exit). Routes
    /// the daemon's term-keyed frames (output / exit / signals) to the OWNING
    /// board — so a backgrounded board's output feeds its detached view and its
    /// card signals update the right board, never the active one.
    var termIndex = TermBoardIndex()

    /// The active board's doc registry (each board owns its own). The chrome
    /// (card headers, counts) reads the active board's docs; the few
    /// cross-board mutations (a `tarmac open` / file event for a doc on a
    /// backgrounded board) target that board's store explicitly.
    var store: DocStore { activeBoard.store }

    var sessions: [String: TerminalSession] {
        get { activeBoard.sessions }
        set { activeBoard.sessions = newValue }
    }
    var sessionOrder: [String] {
        get { activeBoard.sessionOrder }
        set { activeBoard.sessionOrder = newValue }
    }
    var primeTermID: String? {
        get { activeBoard.primeTermID }
        set { activeBoard.primeTermID = newValue }
    }
    var docOwner: [String: String] {
        get { activeBoard.docOwner }
        set { activeBoard.docOwner = newValue }
    }
    var preFlightViewport: Viewport? {
        get { activeBoard.preFlightViewport }
        set { activeBoard.preFlightViewport = newValue }
    }
    // Read-only computed accessors (pure functions of the active board's state).
    var primeSession: TerminalSession? { activeBoard.primeSession }
    var primeTerminalView: TerminalView? { activeBoard.primeTerminalView }
    var primeTermCard: CardView? { activeBoard.primeTermCard }
    var boardDocPaths: [String] { activeBoard.boardDocPaths }

    // M3: the app tracks the board list + the active board from `board_list`
    // (P4 renders the ⌘K switcher from it).
    var boardMetas: [BoardMeta] = []
    // True from a switch's leave until its arrive completes. Suppresses layout
    // persistence across the transient (unmount / re-mount / rebuild)
    // and tells the restore handler to mount the arriving board (crit B4).
    var switching = false

    // M3 P4: the titlebar session chip (`▞ <board>`), hosted in a leading
    // titlebar accessory; shows the active board + dims with the ⌘K switcher.
    let titleChip = TitleBarChip()

    // MARK: - Board placement rule (crib §4/§5)
    //
    // World-frame defaults for fresh placement and the M1→v4 restore scatter.
    // Sizes follow the crib's illustrative B2 frames (term 470×330, doc 392×310);
    // gaps are the illustrative ~86px horizontal / 32px vertical.
    enum Place {
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

    /// True while the ⌘K overlay is up; gates the key monitor (it owns the
    /// keyboard) and tells `board_list` updates to re-render the panel live.
    var switcherOpen = false
    /// The type-to-filter query (prefix match on each board's display label).
    var switcherFilter = ""
    /// The keyboard-highlighted row among the *visible* (filtered) rows.
    var switcherSelected = 0
    /// The rendered rows (pure view-model row + the board's thumbnail items),
    /// rebuilt on open / filter change / `board_list`.
    var switcherRows: [SwitcherRowVM] = []
    /// P5.4: inline rename mode — the header becomes an edit prompt over
    /// `switcherEditBuffer` (seeded from the selected row). ⏎ commits, esc cancels.
    var switcherEditing = false
    var switcherEditBuffer = ""
    /// P5.4: the one-key delete-confirm latch — armed by ⌘⌫, confirmed by a second
    /// ⌘⌫, disarmed by any other key.
    var switcherConfirmingDelete = false

    /// Shared HH:mm formatter (en_US_POSIX). DateFormatter construction is
    /// expensive (ICU / locale load), and `edgeLabel` runs per doc-edge per
    /// reproject — i.e. per pan/zoom frame — so a fresh alloc each call was real
    /// per-frame cost. One cached instance, reused (fix #4). MainActor-confined.
    static let hhmmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// The board that owns `termID` (via the term→board index), or nil if the
    /// term is unknown / already exited.
    func ownerBoard(ofTerm termID: String) -> Board? {
        guard let bid = termIndex.board(of: termID) else { return nil }
        return boards[bid]
    }

    /// The session backing `termID` on its owning board, across all boards.
    func session(ofTerm termID: String) -> TerminalSession? {
        ownerBoard(ofTerm: termID)?.sessions[termID]
    }

    init(window: NSWindow, rootView: RootView) {
        self.window = window
        self.rootView = rootView
        self.client = DaemonClient()

        // board-0 wraps the BoardView RootView was built with; it is the active,
        // mounted board until the daemon's board_list says otherwise.
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
        // Phase 4 wayfinding: supply the per-card offscreen-hint models (label +
        // priority) the board can't derive on its own (doc metadata / recency).
        // Reads `activeBoard` dynamically, so it tracks the mounted board.
        rootView.offscreenHintProvider = { [weak self] in self?.offscreenHints() ?? [] }
        // ⌘K switcher (P4): a row click opens that board; a veil click dismisses.
        rootView.boardSwitcher.onPickRow = { [weak self] index in self?.switcherPickRow(index) }
        rootView.boardSwitcher.onDismiss = { [weak self] in self?.closeSwitcher() }
        // Mount board-0 and bind its per-board callbacks (edge labels + layout
        // persistence). The same `mount(_:)` runs on every switch-arrive.
        mount(board0)

        // M3 P4: host the session chip in the titlebar (hides the redundant
        // native title) and seed it with board-0's name.
        setupTitlebar()
    }

    /// Installs the titlebar session chip as a leading accessory and hides the
    /// native window title (the chip carries the board identity instead).
    private func setupTitlebar() {
        window?.titleVisibility = .hidden
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = titleChip
        window?.addTitlebarAccessoryViewController(accessory)
        updateTitleChip()
    }

    /// Refreshes the titlebar chip with the active board's display name.
    func updateTitleChip() {
        titleChip.setName(activeBoard.name ?? activeBoardID)
    }

    /// P5 (two honest signals): the app-local attached/detached signal. The chip
    /// + status-bar word reflect whether we currently hold a live daemon
    /// connection (the daemon cannot tell a gone app that it detached, so this is
    /// driven locally by `connected`). Reconnect (P5.3) flips it back to attached.
    func updateSessionLiveness() {
        titleChip.setAttached(connected)
        rootView.statusBar.setSession(attached: connected)
    }

    /// Makes the prime terminal the window's first responder (initial focus): the
    /// terminal is the default first responder so typing lands in the shell.
    func focusPrimeTerminal() {
        if let view = primeTerminalView { window?.makeFirstResponder(view) }
    }

    /// perf/whiteboard-profiling: when `TARMAC_PERF_BENCH=1`, run the scripted
    /// zoom-sweep on the mounted board once the window has presented, print the
    /// per-level baseline to stderr, then quit. The sweep drives `reprojectAll`
    /// directly (never `onLayoutChanged`), and `shutdown()` doesn't persist, so
    /// the real on-disk layout is never touched. Removable with PerfTrace.
    func runPerfBenchmarkIfRequested() {
        guard PerfTrace.benchmarkRequested else { return }
        let iters = ProcessInfo.processInfo.environment["TARMAC_PERF_BENCH_ITERS"].flatMap { Int($0) } ?? 80
        // Defer one beat so the window has presented + drawn before we force redraws.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            FileHandle.standardError.write(Data("⟦perf⟧ benchmark start (iters=\(iters))\n".utf8))
            self.activeBoard.view.runBenchmark(iterations: iters, levels: [1.0, 0.51, 0.49, 0.28])

            // Fix #2 check: a burst of onLayoutChanged-equivalent schedulePersist
            // calls (each = one scroll delta) must collapse to ONE pending persist;
            // flushing it then runs persistLayout exactly once. Tests the coalescing
            // invariant directly (no dependence on the debounce timer firing under a
            // headless run loop). With the old per-event persist this would be 30.
            let burst = 30
            for _ in 0..<burst { self.schedulePersist(boardID: self.activeBoardID) }
            self.flushPendingPersist()
            PerfTrace.flush("persist-coalesce: \(burst) schedulePersist ->")

            FileHandle.standardError.write(Data("⟦perf⟧ benchmark done\n".utf8))
            NSApp.terminate(nil)
        }
    }

    /// P5.3: cancel the reconnect loop and close the socket on app teardown. Sets
    /// `quitting` first so any in-flight backoff timer is a no-op, removes the key
    /// monitor, and closes the client (so its disconnect path won't re-fire).
    func shutdown() {
        quitting = true
        for monitor in [escMonitor, clickFocusMonitor, scrollRouteMonitor, magnifyRouteMonitor, mouseUpRestackMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        escMonitor = nil
        clickFocusMonitor = nil
        scrollRouteMonitor = nil
        magnifyRouteMonitor = nil
        mouseUpRestackMonitor = nil
        client.close()
    }
}
