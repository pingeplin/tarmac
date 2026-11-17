import AppKit
import TarmacKit
import TarmacTerm

/// Content view: the infinite whiteboard (`BoardView`) fills the window above a
/// 27px status bar, with the wayfinding chrome and the toast overlay layered on
/// top.
@MainActor
final class RootView: NSView, FontFollowing, ThemeFollowing {
    /// The mounted whiteboard. There is one `BoardView` per board; `mountBoard(_:)`
    /// swaps which one is shown on a board switch. RootView owns only *which*
    /// view is displayed — the controller owns each board's cards + viewport.
    private(set) var board = BoardView()
    let statusBar = StatusBar()
    let toasts = ToastStackView()
    // Wayfinding: zoom control (bottom-left), minimap (bottom-right) and the
    // edge pills for signalling cards that are off screen.
    let zoomControl = ZoomControl()
    let minimap = Minimap()
    private let offHints = OffscreenHints()
    // The ⌘K boards switcher (veil + centered panel), modal; hidden until ⌘K.
    // The controller drives its contents + key handling.
    let boardSwitcher = BoardSwitcherView()
    let restoreCard = RestoreCardView()
    let inboxPanel = InboxPanelView()

    /// Supplies the mounted board's signalling cards whose centre is outside
    /// the given board-local rect, in card order. The controller knows the
    /// labels and bell times the board does not.
    var offscreenHintProvider: ((CGRect) -> [OffscreenHintLayout.Hint])?

    /// Where ⏎ flies: the off-screen signal that ranks highest, if there is one.
    private(set) var offscreenFlyTarget: CardID?
    /// The pills as last placed, for the QA driver.
    private(set) var placedHints: [OffscreenHintLayout.PlacedPill] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor

        addSubview(board)
        addSubview(statusBar)
        boardSwitcher.isHidden = true
        inboxPanel.isHidden = true
        for layer in OverlayStack.backToFront { addSubview(overlay(layer)) }
        board.mountUnderCards(offHints.under)

        // −/+ zoom about the viewport center; fit frames every card.
        zoomControl.onZoomOut = { [weak self] in
            self?.board.zoom(by: 1 / ZoomControl.zoomStep)
        }
        zoomControl.onZoomIn = { [weak self] in
            self?.board.zoom(by: ZoomControl.zoomStep)
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
        toasts.onChange = { [weak self] in
            guard let self else { return }
            self.refreshWayfinding(self.board.viewport)
        }
        // Refresh the chrome off the live viewport / card set.
        wireBoardCallbacks(board)
        zoomControl.setZoom(board.viewport.zoom)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func overlay(_ layer: OverlayStack) -> NSView {
        switch layer {
        case .hints: return offHints.over
        case .zoomControl: return zoomControl
        case .minimap: return minimap
        case .toasts: return toasts
        case .switcher: return boardSwitcher
        case .restoreCard: return restoreCard
        case .inbox: return inboxPanel
        }
    }

    /// Wires a board view's wayfinding callbacks to this RootView — called for
    /// the initial board in `init` and for each board mounted by `mountBoard`.
    /// (`onLayoutChanged` and the card callbacks are owned by AppController and
    /// re-bound there on mount; the zoom/minimap actions read `self.board`
    /// dynamically so they always target the mounted board.)
    private func wireBoardCallbacks(_ bv: BoardView) {
        bv.onViewportChanged = { [weak self] vp in self?.refreshWayfinding(vp) }
        bv.onCardsChanged = { [weak self] in self?.cardsChanged() }
    }

    /// Mounts `bv` as the shown whiteboard: detaches the current board view and
    /// inserts `bv` as the bottom-most subview (below the status bar and every
    /// overlay), re-wiring its wayfinding callbacks and moving the under-card
    /// pill layer into it. Used by the controller on every board switch-arrive
    /// (and to re-mount the same view after `unmountBoard`). The detached
    /// board's cards + live terminal views stay parented to it off-window, so
    /// background ptys keep running.
    func mountBoard(_ bv: BoardView) {
        guard board !== bv || bv.superview == nil else { return }
        if board !== bv { board.removeFromSuperview() }
        bv.removeFromSuperview()
        board.alphaValue = 1
        board = bv
        board.alphaValue = boardAlpha
        addSubview(bv, positioned: .below, relativeTo: statusBar)
        bv.mountUnderCards(offHints.under)
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

    /// The inbox panel's width follows the Interface size.
    func fontsChanged() {
        offHints.forget()
        refreshWayfinding(board.viewport)
        needsLayout = true
    }

    private var inboxMaxWidth: CGFloat { Theme.chrome(InboxPanelLayout.maxWidth) }

    /// A pill is reused while what it says is the same, which a new colour
    /// does not change.
    func themeChanged() {
        layer?.backgroundColor = Theme.bg0.cgColor
        offHints.forget()
        refreshWayfinding(board.viewport)
    }

    /// Rebuilds the wayfinding chrome from the current viewport + card set: the
    /// zoom readout, the minimap rects + viewport box, and the edge pills.
    /// Cheap; called on every viewport / card change.
    func refreshWayfinding(_ viewport: Viewport) {
        zoomControl.setZoom(viewport.zoom)
        minimap.update(items: board.minimapItems, viewportWorldRect: board.viewportWorldRect)
        // An open inbox covers the board's right strip: a card under it is off
        // screen, and the pills keep to what it leaves (2611.0013, D12).
        let visible = InboxPanelLayout.uncovered(board.bounds, open: !inboxPanel.isHidden, maxWidth: inboxMaxWidth)
        let selection = OffscreenHintLayout.select(offscreenHintProvider?(visible) ?? [])
        placedHints = offHints.show(
            selection.shown, in: visible, around: board.cards.values.map(\.frame), clearOf: chromeOverHints
        )
        // Only terminals signal, so a hint's id is a terminal's.
        offscreenFlyTarget = selection.flyTarget.map(CardID.term)
    }

    /// The corner chrome drawn over the pills (`OverlayStack.pillChrome`), in
    /// the board's coordinates: each toast, not the column's sheet.
    private var chromeOverHints: [CGRect] {
        OverlayStack.pillChrome.flatMap { layer -> [CGRect] in
            layer == .toasts
                ? toasts.frames.map { board.convert($0, from: toasts) }
                : [board.convert(overlay(layer).frame, from: self)]
        }
    }

    /// Shows / hides the ⌘K boards switcher overlay (the controller renders its
    /// rows + handles keys; this only flips visibility and re-lays-out).
    func setSwitcherVisible(_ visible: Bool) {
        guard visible != !boardSwitcher.isHidden else { return }
        boardSwitcher.isHidden = !visible
        needsLayout = true
    }

    /// Shows / hides the inbox panel; the board keeps its frame under it.
    func setInboxVisible(_ visible: Bool) {
        guard visible != !inboxPanel.isHidden else { return }
        inboxPanel.isHidden = !visible
        needsLayout = true
    }

    /// Shows the restore card, and dims the board under it to the v3 desk's
    /// 35%; nil hides it.
    func setRestoreCard(_ card: RestoreCard?) {
        if let card { restoreCard.show(card) } else { restoreCard.hide() }
        board.alphaValue = boardAlpha
        needsLayout = true
    }

    private var boardAlpha: CGFloat { restoreCard.isHidden ? 1 : 0.35 }

    /// The window above the status bar: the board, and what every overlay is
    /// measured from.
    private var boardArea: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - StatusBar.height))
    }

    override func layout() {
        super.layout()
        let area = boardArea
        board.frame = area
        statusBar.frame = NSRect(x: 0, y: area.maxY, width: bounds.width, height: StatusBar.height)

        let uncovered = InboxPanelLayout.uncovered(area, open: !inboxPanel.isHidden, maxWidth: inboxMaxWidth)
        offHints.over.frame = area
        toasts.frame = uncovered
        // Zoom control: bottom-left, left 12, 12 above the status bar.
        zoomControl.sizeToContents()
        let zc = zoomControl.frame.size
        zoomControl.frame = NSRect(x: 12, y: area.maxY - 12 - zc.height, width: zc.width, height: zc.height)
        // Minimap: bottom-right, right 12, 12 above the status bar.
        minimap.frame = NSRect(
            x: uncovered.maxX - 12 - Minimap.mapWidth,
            y: area.maxY - 12 - Minimap.mapHeight,
            width: Minimap.mapWidth,
            height: Minimap.mapHeight
        )
        toasts.keepAbove = toasts.convert(minimap.frame, from: self)

        // ⌘K switcher: covers the board area and leaves the status bar legible;
        // the panel centers itself within.
        if !boardSwitcher.isHidden { boardSwitcher.frame = area }
        if !restoreCard.isHidden { restoreCard.frame = area }
        if !inboxPanel.isHidden { inboxPanel.frame = InboxPanelLayout.panelRect(area, maxWidth: inboxMaxWidth) }
        cardsChanged()
    }
}

private extension BoardView {
    /// Puts `sheet` over the provenance edges and under every card. The board
    /// keeps its two layers private, so the edge layer is found by its type.
    func mountUnderCards(_ sheet: NSView) {
        guard let edges = subviews.first(where: { $0 is EdgeLayerView }) else { return }
        sheet.frame = bounds
        sheet.autoresizingMask = [.width, .height]
        addSubview(sheet, positioned: .above, relativeTo: edges)
    }
}
