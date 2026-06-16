import AppKit
import QuartzCore
import SwiftTerm

/// Content view: the infinite whiteboard (`BoardView`) fills the window above a
/// 27px status bar, with the shelf overlay (top-left), the cold-start hint, the
/// peek slide-over, and the toast overlay layered on top. The dock/index rails
/// were retired in Phase 3 (the shelf replaces the dock).
@MainActor
final class RootView: NSView {
    /// The mounted whiteboard. M3: one `BoardView` per board; `mountBoard(_:)`
    /// swaps which one is shown on a board switch. RootView owns only *which*
    /// view is displayed — the controller owns each board's cards + viewport.
    private(set) var board = BoardView()
    let shelf = ShelfView()
    let statusBar = StatusBar()
    let coldStartHint = ColdStartHintView()
    let peek = PeekPanel()
    let toasts = ToastStackView()
    // Phase 4 wayfinding chrome (crib §6): zoom control (bottom-left), minimap
    // (bottom-right), and offscreen-signal hint pills (pinned to viewport edges).
    let zoomControl = ZoomControl()
    let minimap = Minimap()
    let offHints = OffscreenHints()
    // Phase 5a terminal primacy: the cockpit dock pane (fixed to the board's
    // bottom; hidden until a terminal docks) and the ⌥tab cycle HUD (top-center).
    let dockPane = DockPaneView()
    let cycleHUD = CycleHUD()
    // M3 P4: the ⌘K boards switcher overlay (veil + centered panel), topmost and
    // modal; hidden until ⌘K. The controller drives its contents + key handling.
    let boardSwitcher = BoardSwitcherView()

    /// Whether the cockpit dock is currently showing a docked terminal. The
    /// controller drives the reparent; RootView only owns the layout.
    private(set) var dockVisible = false

    private(set) var peekVisible = false
    private var peekAnimating = false

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
        coldStartHint.isHidden = true
        addSubview(coldStartHint)
        // Shelf floats over the board's top-left; hidden until non-empty.
        addSubview(shelf)
        // Wayfinding overlays sit above the board, below peek/toasts. The hint
        // overlay is click-through and spans the board.
        addSubview(offHints)
        addSubview(zoomControl)
        addSubview(minimap)

        // Cockpit dock pane sits above the board chrome (it covers the board's
        // bottom while docked) but below peek/toasts; hidden until a dock.
        dockPane.isHidden = true
        addSubview(dockPane)
        // Cycle HUD floats above the dock, top-center; hidden until ⌥tab.
        cycleHUD.isHidden = true
        addSubview(cycleHUD)

        peek.isHidden = true
        addSubview(peek)
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
        bv.onCardsChanged = { [weak self] in self?.refreshWayfinding(self?.board.viewport) }
    }

    /// Mounts `bv` as the shown whiteboard: detaches the current board view and
    /// inserts `bv` as the bottom-most subview (below the status bar and the
    /// click-through hint overlay), re-wiring its wayfinding callbacks. Used by
    /// the controller on every board switch-arrive (and to re-mount the same view
    /// after `unmountBoard`). The detached board's cards + live SwiftTerm views
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
    /// chrome; its cards + live SwiftTerm views stay parented to it (ptys live).
    func unmountBoard() {
        board.onViewportChanged = nil
        board.onCardsChanged = nil
        board.removeFromSuperview()
    }

    /// Rebuilds the wayfinding chrome from the current viewport + card set: the
    /// zoom readout, the minimap rects + viewport box, and the offscreen-hint
    /// pills. Cheap; called on every viewport / card change.
    func refreshWayfinding(_ viewport: Viewport?) {
        PerfTrace.measure("wayfind") {
            let vp = viewport ?? board.viewport
            zoomControl.setZoom(vp.zoom)
            minimap.update(items: board.minimapItems, viewportWorldRect: board.viewportWorldRect)
            let hints = offscreenHintProvider?() ?? []
            // The hint overlay shares the board's coordinate space (same frame).
            offHints.update(hints: hints, viewRect: board.bounds)
        }
    }

    /// The card the Return flight should fly to (most-recent offscreen signal),
    /// or nil. The controller reads this for the ⏎ key.
    var offscreenFlyTarget: CardID? { offHints.targetCardID }

    func attachTerminal(_ terminal: TerminalView, termID: String, worldFrame: CardFrame) {
        board.setTerminal(termID: termID, terminal, worldFrame: worldFrame)
    }

    /// Shows / hides the cockpit dock pane. The controller does the SwiftTerm
    /// reparent + board slot-ghost separately; this only flips visibility and
    /// re-lays-out so the pane occupies the board's bottom 40%.
    func setDockVisible(_ visible: Bool) {
        guard visible != dockVisible else { return }
        dockVisible = visible
        dockPane.isHidden = !visible
        needsLayout = true
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
        // Cold-start hint: one line just above the status bar, full width.
        coldStartHint.frame = NSRect(x: 0, y: boardHeight - 28, width: bounds.width, height: 20)
        // The shelf sizes itself (top-left at 12,12); nothing to lay out here.

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

        // Cockpit dock pane: fixed to the bottom of the board area (left 0,
        // right 0, bottom at boardHeight — above the status bar), height = 40%
        // of the board height (crib §4).
        let dockH = (boardHeight * DockPaneView.heightFraction).rounded()
        dockPane.frame = NSRect(x: 0, y: boardHeight - dockH, width: bounds.width, height: dockH)

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

        if !peekAnimating {
            peek.frame = peekFrame(visible: peekVisible)
        }
        toasts.frame = bounds
        // ⌘K switcher: covers the board area (the status bar stays legible below,
        // showing the board count); the panel centers itself within.
        if !boardSwitcher.isHidden {
            boardSwitcher.frame = NSRect(x: 0, y: 0, width: bounds.width, height: boardHeight)
        }
        refreshWayfinding(board.viewport)
    }

    func peekFrame(visible: Bool) -> NSRect {
        let width = (bounds.width * 0.47).rounded()
        // Hidden = translateX(102%) per the design.
        let x = visible ? bounds.width - width : bounds.width + (width * 0.02).rounded()
        return NSRect(x: x, y: 0, width: width, height: bounds.height)
    }

    func setPeekVisible(_ visible: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard visible != peekVisible else {
            completion?()
            return
        }
        peekVisible = visible
        let target = peekFrame(visible: visible)

        if Theme.reduceMotion {
            peek.frame = target
            peek.isHidden = !visible
            completion?()
            return
        }

        peek.isHidden = false
        peek.frame = peekFrame(visible: !visible)
        peek.needsLayout = true
        peekAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            peek.animator().frame = target
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.peekAnimating = false
                self.peek.isHidden = !self.peekVisible
                self.needsLayout = true
                completion?()
            }
        })
    }
}
