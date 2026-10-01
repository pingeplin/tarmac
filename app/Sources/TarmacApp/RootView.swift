import AppKit
import TarmacTerm

/// Content view: the infinite whiteboard (`BoardView`) fills the window above a
/// 27px status bar, with the wayfinding chrome and the toast overlay layered on
/// top.
@MainActor
final class RootView: NSView {
    /// The mounted whiteboard. M3: one `BoardView` per board; `mountBoard(_:)`
    /// swaps which one is shown on a board switch. RootView owns only *which*
    /// view is displayed — the controller owns each board's cards + viewport.
    private(set) var board = BoardView()
    let statusBar = StatusBar()
    let toasts = ToastStackView()
    // Phase 4 wayfinding chrome (crib §6): zoom control (bottom-left), minimap
    // (bottom-right), and offscreen-signal hint pills (pinned to viewport edges).
    let zoomControl = ZoomControl()
    let minimap = Minimap()
    let offHints = OffscreenHints()
    // The ⌥tab cycle HUD (top-center).
    let cycleHUD = CycleHUD()
    // M3 P4: the ⌘K boards switcher overlay (veil + centered panel), topmost and
    // modal; hidden until ⌘K. The controller drives its contents + key handling.
    let boardSwitcher = BoardSwitcherView()

    /// Supplies the per-card offscreen-hint models (label + priority) — the
    /// controller knows the doc/term metadata the board doesn't. Set by
    /// AppController; nil yields no hints.
    var offscreenHintProvider: (() -> [OffscreenHints.Hint])?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor

        addSubview(board)
        addSubview(statusBar)
        // Wayfinding overlays sit above the board, below the toasts. The hint
        // overlay is click-through and spans the board.
        addSubview(offHints)
        addSubview(zoomControl)
        addSubview(minimap)

        // Cycle HUD floats top-center; hidden until ⌥tab.
        cycleHUD.isHidden = true
        addSubview(cycleHUD)

        addSubview(toasts)
        // The ⌘K switcher is the topmost overlay (modal veil over everything).
        boardSwitcher.isHidden = true
        addSubview(boardSwitcher)

        // Zoom control actions (crib §6): −/+ anchored at the viewport center;
        // fit = bounding box of all cards.
        zoomControl.onZoomOut = { [weak self] in
            self?.board.zoom(by: 1 / ZoomControl.zoomStep, commit: true)
        }
        zoomControl.onZoomIn = { [weak self] in
            self?.board.zoom(by: ZoomControl.zoomStep, commit: true)
        }
        zoomControl.onFit = { [weak self] in self?.board.fitToCards() }
        // Minimap click → re-center the viewport on the clicked world point.
        minimap.onJump = { [weak self] world in
            guard let self else { return }
            var vp = self.board.viewport
            vp.cx = world.x
            vp.cy = world.y
            self.board.setViewport(vp, commit: true)
        }
        // Refresh the chrome off the live viewport / card set.
        wireBoardCallbacks(board)
        zoomControl.setZoom(board.viewport.zoom)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Wires a board view's wayfinding callbacks to this RootView — called for
    /// the initial board in `init` and for each board mounted by `mountBoard`.
    /// (`edgeLabelProvider` / `onLayoutChanged` are owned by AppController and
    /// re-bound there on mount; the zoom/minimap actions read `self.board`
    /// dynamically so they always target the mounted board.)
    private func wireBoardCallbacks(_ bv: BoardView) {
        bv.onViewportChanged = { [weak self] vp in self?.refreshWayfinding(vp) }
        bv.onCardsChanged = { [weak self] in self?.cardsChanged() }
    }

    /// Mounts `bv` as the shown whiteboard: detaches the current board view and
    /// inserts `bv` as the bottom-most subview (below the status bar and the
    /// click-through hint overlay), re-wiring its wayfinding callbacks. Used by
    /// the controller on every board switch-arrive (and to re-mount the same view
    /// after `unmountBoard`). The detached board's cards + live terminal views
    /// stay parented to it off-window, so background ptys keep running.
    func mountBoard(_ bv: BoardView) {
        guard board !== bv || bv.superview == nil else { return }
        if board !== bv { board.removeFromSuperview() }
        bv.removeFromSuperview()
        board = bv
        addSubview(bv, positioned: .below, relativeTo: statusBar)
        wireBoardCallbacks(bv)
        needsLayout = true
    }

    /// Detaches the mounted board view (switch-away) without yet mounting another.
    /// Its callbacks are cleared so the off-window view never drives the active
    /// chrome; its cards + live terminal views stay parented to it (ptys live).
    func unmountBoard() {
        board.onViewportChanged = nil
        board.onCardsChanged = nil
        board.removeFromSuperview()
    }

    /// The mounted board's card set, a card's frame or a card's signal changed.
    private func cardsChanged() {
        statusBar.setCardCount(board.cards.count)
        refreshWayfinding(board.viewport)
    }

    /// Rebuilds the wayfinding chrome from the current viewport + card set: the
    /// zoom readout, the minimap rects + viewport box, and the offscreen-hint
    /// pills. Cheap; called on every viewport / card change.
    func refreshWayfinding(_ viewport: Viewport?) {
        let vp = viewport ?? board.viewport
        zoomControl.setZoom(vp.zoom)
        minimap.update(items: board.minimapItems, viewportWorldRect: board.viewportWorldRect)
        let hints = offscreenHintProvider?() ?? []
        // The hint overlay shares the board's coordinate space (same frame).
        offHints.update(hints: hints, viewRect: board.bounds)
    }

    /// The card the Return flight should fly to (most-recent offscreen signal),
    /// or nil. The controller reads this for the ⏎ key.
    var offscreenFlyTarget: CardID? { offHints.targetCardID }

    func attachTerminal(_ terminal: TerminalView, termID: String, worldFrame: CardFrame) {
        board.setTerminal(termID: termID, terminal, worldFrame: worldFrame)
    }

    /// Shows / hides the ⌘K boards switcher overlay (the controller renders its
    /// rows + handles keys; this only flips visibility and re-lays-out).
    func setSwitcherVisible(_ visible: Bool) {
        guard visible != !boardSwitcher.isHidden else { return }
        boardSwitcher.isHidden = !visible
        needsLayout = true
    }

    /// Board height = window minus the 27px status bar (migration-plan Phase 3).
    private var boardHeight: CGFloat { max(0, bounds.height - StatusBar.height) }

    override func layout() {
        super.layout()
        board.frame = NSRect(x: 0, y: 0, width: bounds.width, height: boardHeight)
        statusBar.frame = NSRect(x: 0, y: boardHeight, width: bounds.width, height: StatusBar.height)

        // Offscreen-hint overlay spans the board (its hint coords are board-space).
        offHints.frame = NSRect(x: 0, y: 0, width: bounds.width, height: boardHeight)
        // Zoom control: bottom-left, left 12, 12 above the status bar.
        zoomControl.sizeToContents()
        let zc = zoomControl.frame.size
        zoomControl.frame = NSRect(x: 12, y: boardHeight - 12 - zc.height, width: zc.width, height: zc.height)
        // Minimap: bottom-right, right 12, 12 above the status bar.
        minimap.frame = NSRect(
            x: bounds.width - 12 - Minimap.mapWidth,
            y: boardHeight - 12 - Minimap.mapHeight,
            width: Minimap.mapWidth,
            height: Minimap.mapHeight
        )

        // Cycle HUD: centered horizontally, top 12 in the board's coordinate
        // space (the board fills from y=0 to boardHeight).
        if !cycleHUD.isHidden {
            cycleHUD.sizeToContents()
            let size = cycleHUD.frame.size
            cycleHUD.frame = NSRect(
                x: ((bounds.width - size.width) / 2).rounded(),
                y: CycleHUD.topInset,
                width: size.width,
                height: size.height
            )
        }

        toasts.frame = bounds
        // ⌘K switcher: covers the board area (the status bar stays legible below,
        // showing the board count); the panel centers itself within.
        if !boardSwitcher.isHidden {
            boardSwitcher.frame = NSRect(x: 0, y: 0, width: bounds.width, height: boardHeight)
        }
        cardsChanged()
    }
}
