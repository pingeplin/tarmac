import AppKit
import QuartzCore
import SwiftTerm

/// Content view: the infinite whiteboard (`BoardView`) fills the window above a
/// 27px status bar, with the shelf overlay (top-left), the cold-start hint, the
/// peek slide-over, and the toast overlay layered on top. The dock/index rails
/// were retired in Phase 3 (the shelf replaces the dock).
@MainActor
final class RootView: NSView {
    let board = BoardView()
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

        peek.isHidden = true
        addSubview(peek)
        addSubview(toasts)

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
        board.onViewportChanged = { [weak self] vp in self?.refreshWayfinding(vp) }
        board.onCardsChanged = { [weak self] in self?.refreshWayfinding(self?.board.viewport) }
        zoomControl.setZoom(board.viewport.zoom)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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

    func attachTerminal(_ terminal: TerminalView, worldFrame: CardFrame) {
        board.setTerminal(terminal, worldFrame: worldFrame)
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

        if !peekAnimating {
            peek.frame = peekFrame(visible: peekVisible)
        }
        toasts.frame = bounds
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
