import AppKit
import TarmacKit
import TarmacTerm

/// One terminal card's live state (the board holds N of these). Owns the
/// terminal view and the per-terminal signal/process bookkeeping. `live` is
/// whether the pty is running (false before first spawn and after exit). The
/// exited/dead visual state lives on the board card (`CardView.dead`), not here.
@MainActor
final class TerminalSession {
    let termID: String
    let view: TerminalView
    /// Whether the pty backing this card is currently running.
    var live = false
    /// Header label: the displayed title — an OSC title if one is set, else the
    /// foreground process name, else the shell basename. Recomputed from the
    /// sources below via `TermTitle.displayLabel`; never written directly.
    var label = ""
    /// The shell basename resolved at spawn — idle ⇔ foreground == shellName.
    var shellName = ""
    /// Latest foreground process name pushed by the daemon (`term_proc`). Tracked
    /// independently of `label` so the title can revert here when an OSC title is
    /// cleared. nil/"" before the first `term_proc`.
    var procName: String?
    /// Latest non-empty OSC title (OSC 0/1/2) the running program emitted. Takes
    /// precedence over `procName`. Cleared to nil when the program emits an
    /// empty OSC title (`ESC ] 2 ; ST`).
    var oscTitle: String?
    /// Last cols/rows sent to the daemon — debounces duplicate resizes.
    var lastSentCols = 0
    var lastSentRows = 0

    init(termID: String, view: TerminalView) {
        self.termID = termID
        self.view = view
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
    // On a dropped daemon connection the app marks its live sessions detached,
    // flips the chip/status faint, and retries `connect()` on the bounded
    // `Reconnect` backoff. A successful reconnect's `board_list` + `restore`
    // revive the still-live shells (and cold-spawn the gone ones) via the boards
    // queued in `boardsAwaitingRevive`.
    /// Attempts made since the link last dropped (reset to 0 on `hello_ok`).
    var reconnectAttempt = 0
    /// A `connect()` is in flight on the background queue — guards double-connect.
    var reconnecting = false
    /// App teardown began — gates the scheduler so a pending backoff is a no-op.
    var quitting = false
    /// Boards whose detached terminals await revive on the next restore for them.
    /// Populated on disconnect (every board that had a live session); a board is
    /// removed when its revive runs. Also gates `maybeSpawn` so a detached prime
    /// is never cold-spawned over its surviving shell during the reconnect window.
    var boardsAwaitingRevive: Set<String> = []

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
    private var didInitialRestore: Bool {
        get { activeBoard.didInitialRestore }
        set { activeBoard.didInitialRestore = newValue }
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

    /// The board whose layout a settling pan still owes to disk, and the trailing
    /// timer that will flush it. Only the continuous `onLayoutChanged` path is
    /// debounced; discrete `persistLayout()` calls (spawn / close / …) stay
    /// immediate.
    var pendingPersistBoardID: String?
    var persistDebounce: DispatchWorkItem?
    static let persistDebounceInterval: TimeInterval = 0.2

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

        updateWindowTitle()
    }

    /// Names the active board in the window title, which is what the Dock,
    /// Exposé and the window list show for the app.
    func updateWindowTitle() {
        window?.title = WindowTitle.text(
            boardName: boardMetas.first { $0.boardID == activeBoardID }?.name,
            boardID: activeBoardID,
            devLabel: ProcessInfo.processInfo.environment["TARMAC_DEV_LABEL"]
        )
    }

    /// P5 (two honest signals): the app-local attached/detached signal. The
    /// status-bar word reflects whether we currently hold a live daemon
    /// connection (the daemon cannot tell a gone app that it detached, so this is
    /// driven locally by `connected`). Reconnect (P5.3) flips it back to attached.
    func updateSessionLiveness() {
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
