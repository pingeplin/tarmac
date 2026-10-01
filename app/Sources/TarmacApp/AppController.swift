import AppKit
import TarmacKit
import TarmacTerm

/// One terminal card's state (the board holds N of these): the terminal view
/// and what the app knows about the PTY behind it. Whether the card is dead
/// lives on the board card (`CardView.dead`), not here.
@MainActor
final class TerminalSession {
    let termID: String
    let view: TerminalView
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

    /// The PTY exists daemon-side as far as the app knows, so input and
    /// resizes may be sent for it.
    var reachable: Bool { live && !needsSpawn }

    init(termID: String, view: TerminalView) {
        self.termID = termID
        self.view = view
    }

    func feed(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        view.feed(bytes)
    }
}

@MainActor
final class AppController {
    let client: DaemonClient
    let rootView: RootView
    weak var window: NSWindow?

    /// The handshake has completed: requests may be made. Narrower than
    /// `connectionStatus.connected`, which is already true while it is pending.
    var connected = false
    var viewReady = false
    /// The daemon link as the status bar shows it.
    var connectionStatus = ConnectionStatus.connecting

    var daemonSession = DaemonSession()

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

    /// The selected card: the active board's one selection, which the board
    /// view owns. A press on a card sets it and a press on the bare board clears
    /// it; while set, a wheel over that card's body scrolls the card.
    var focusedCardID: CardID? {
        get { activeBoard.view.selectedID }
        set { activeBoard.view.select(newValue) }
    }

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
        self.client = Self.daemonClient()

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
        updateSessionLiveness()
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

    func updateSessionLiveness() {
        rootView.statusBar.setConnection(connectionStatus)
    }

    /// Makes the prime terminal the window's first responder (initial focus): the
    /// terminal is the default first responder so typing lands in the shell.
    func focusPrimeTerminal() {
        if let view = primeTerminalView { window?.makeFirstResponder(view) }
    }

    /// App teardown: removes the event monitors and closes the daemon link. The
    /// daemon and its terminals are left running.
    func shutdown() {
        for monitor in [escMonitor, clickFocusMonitor, scrollRouteMonitor, magnifyRouteMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        escMonitor = nil
        clickFocusMonitor = nil
        scrollRouteMonitor = nil
        magnifyRouteMonitor = nil
        client.close()
    }
}
