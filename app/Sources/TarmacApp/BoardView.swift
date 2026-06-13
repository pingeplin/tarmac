import AppKit
import QuartzCore
import TarmacKit

/// The infinite whiteboard (crib §5) — the v4 successor to `DeskGridView`.
/// Strip = board; terminal and docs are free `CardView`s placed by world frame.
///
/// World↔view transform: `view = (world − center)·zoom + viewportCenter`, where
/// `center = (viewport.cx, viewport.cy)` (world) and `viewportCenter` is the
/// board's view-space midpoint. Both spaces are top-down (this view is flipped),
/// so a card's world `top` maps to a smaller view `y`.
///
/// Background dot grid is drawn in board space (radial dots, 24px world spacing,
/// denser 11px below the semantic-zoom threshold). The card layer is reprojected
/// on every pan / zoom / layout.
///
/// 2c hosts this in `RootView` in place of `DeskGridView`; this phase the type is
/// unused so the app stays green.
@MainActor
final class BoardView: NSView {
    // Dot grid (crib §5): color #32383e, ~2px dot, 24px world spacing (11px lo-zoom).
    private static let dotColor = NSColor(srgbRed: 50 / 255, green: 56 / 255, blue: 62 / 255, alpha: 1)
    private static let dotRadius: CGFloat = 1
    private static let gridSpacing: CGFloat = 24
    private static let gridSpacingLo: CGFloat = 11
    // board.css background-position: -7px -9px (world-space phase of the lattice).
    private static let gridPhase = CGPoint(x: -7, y: -9)

    // MARK: - Public API (the exact surface Phase 2c calls)

    /// Fires after a *committed* move / resize / zoom / pan, with the current
    /// viewport. 2c persists card world frames + `board {zoom,cx,cy}` here and
    /// reflows the just-resized terminal.
    var onLayoutChanged: ((Viewport) -> Void)?

    /// Current viewport (zoom + world center). Read for persistence; set by 2c
    /// from `restore.board` to reproduce the saved viewport.
    private(set) var viewport: Viewport = .default

    /// All cards by id, in no particular order (z drives stacking).
    private(set) var cards: [CardID: CardView] = [:]

    /// Adds a card at its world frame. If a card with the same id exists it is
    /// replaced. Returns the live view so the caller can attach content.
    @discardableResult
    func addCard(id: CardID, worldFrame: CardFrame) -> CardView {
        removeCard(id: id)
        let card = CardView(id: id, worldFrame: worldFrame)
        wire(card)
        cards[id] = card
        cardLayer.addSubview(card)
        restack()
        reproject(card)
        return card
    }

    func removeCard(id: CardID) {
        guard let card = cards.removeValue(forKey: id) else { return }
        if selectedID == id { selectedID = nil }
        card.removeFromSuperview()
    }

    func card(_ id: CardID) -> CardView? { cards[id] }

    /// Convenience for the (single, this phase) terminal card: ensures a `.term`
    /// card exists at `worldFrame` and attaches the SwiftTerm view into its body.
    /// On restore the `.term` card already exists (created at init), so its world
    /// frame must be *re-applied* here — otherwise persisted move/resize geometry
    /// is silently dropped and the terminal snaps back to its init frame.
    func setTerminal(_ view: NSView, worldFrame: CardFrame) {
        let card: CardView
        if let existing = cards[.term] {
            existing.worldFrame = worldFrame
            reproject(existing)
            restack()
            card = existing
        } else {
            card = addCard(id: .term, worldFrame: worldFrame)
        }
        card.attachTerminal(view)
    }

    /// world → view (point). Inverse of `viewToWorld`. Delegates to the pure
    /// `BoardTransform` in TarmacKit (single source of truth, unit-tested there).
    func worldToView(_ p: CGPoint) -> CGPoint {
        BoardTransform.worldToView(
            p,
            zoom: viewport.zoom,
            center: CGPoint(x: viewport.cx, y: viewport.cy),
            viewportCenter: viewportCenter
        )
    }

    /// view → world (point). Inverse of `worldToView`.
    func viewToWorld(_ p: CGPoint) -> CGPoint {
        BoardTransform.viewToWorld(
            p,
            zoom: viewport.zoom,
            center: CGPoint(x: viewport.cx, y: viewport.cy),
            viewportCenter: viewportCenter
        )
    }

    /// world rect → view rect (origin = card top-left; this view is flipped).
    func worldToView(_ r: CGRect) -> CGRect {
        let origin = worldToView(CGPoint(x: r.minX, y: r.minY))
        return CGRect(x: origin.x, y: origin.y, width: r.width * viewport.zoom, height: r.height * viewport.zoom)
    }

    /// Sets the viewport directly (no commit echo) — used by 2c on restore.
    func setViewport(_ vp: Viewport, commit: Bool = false) {
        viewport = clampZoom(vp)
        reprojectAll()
        updateGridDensity()
        needsDisplay = true
        if commit { onLayoutChanged?(viewport) }
    }

    /// Zoom by a multiplicative factor, anchored so the world point under
    /// `anchorViewPoint` stays put (crib §5: ⌘± / pinch anchored at the pointer).
    /// Pass the pointer location in this view's coordinates; defaults to center.
    func zoom(by factor: CGFloat, anchorViewPoint: CGPoint? = nil, commit: Bool) {
        let anchor = anchorViewPoint ?? viewportCenter
        let worldAnchor = viewToWorld(anchor)
        let newZoom = clampValue(viewport.zoom * factor)
        guard newZoom != viewport.zoom else {
            if commit { onLayoutChanged?(viewport) }
            return
        }
        viewport.zoom = newZoom
        // Solve for the center that keeps worldAnchor under `anchor`.
        let c = viewportCenter
        viewport.cx = worldAnchor.x - (anchor.x - c.x) / newZoom
        viewport.cy = worldAnchor.y - (anchor.y - c.y) / newZoom
        reprojectAll()
        updateGridDensity()
        needsDisplay = true
        if commit { onLayoutChanged?(viewport) }
    }

    /// Selects a card and raises it to front (crib §4: select → front). Pass nil
    /// to clear selection. Does not commit (selection is not persisted state).
    func select(_ id: CardID?) {
        guard id != selectedID else { return }
        if let prev = selectedID { cards[prev]?.setSelected(false) }
        selectedID = id
        if let id, let card = cards[id] {
            card.setSelected(true)
            raiseToFront(card)
        }
    }

    var selectedID: CardID?

    /// esc drag-cancel priority (crib §5): cancels an in-flight move/resize and
    /// restores the pre-gesture world frame. Returns false when no card is
    /// dragging so esc falls through to peek/toast dismissal.
    @discardableResult
    func cancelDrag() -> Bool {
        guard let id = gesturingID, let card = cards[id] else { return false }
        let restored = card.cancelGesture(restoringTo: preGestureFrame)
        if restored {
            reproject(card)
            gesturingID = nil
            preGestureFrame = nil
        }
        return restored
    }

    // MARK: - Internals

    private let cardLayer = FlippedColumnView()
    private var gesturingID: CardID?
    private var preGestureFrame: CardFrame?

    private var viewportCenter: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// Loose zoom clamp (crib §5: no hard bounds authored; keep pinch/⌘± usable).
    private func clampValue(_ z: CGFloat) -> CGFloat {
        min(Viewport.maxZoom, max(Viewport.minZoom, z))
    }

    private func clampZoom(_ vp: Viewport) -> Viewport {
        var vp = vp
        vp.zoom = clampValue(vp.zoom)
        return vp
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor
        cardLayer.frame = bounds
        cardLayer.autoresizingMask = [.width, .height]
        addSubview(cardLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func wire(_ card: CardView) {
        card.worldPerView = 1 / viewport.zoom
        card.onSelectRequested = { [weak self] c in
            guard let self else { return }
            self.beginGesture(on: c)
            self.select(c.id)
        }
        card.onWorldFrameChangedDuringGesture = { [weak self] c in
            // Live reproject; terminal reflow waits for commit (crib §4: reflow
            // terminal once on resize end).
            self?.reproject(c)
        }
        card.onFrameCommitted = { [weak self] c in
            guard let self else { return }
            self.gesturingID = nil
            self.preGestureFrame = nil
            self.reproject(c)
            self.onLayoutChanged?(self.viewport)
        }
    }

    private func beginGesture(on card: CardView) {
        card.worldPerView = 1 / viewport.zoom
        gesturingID = card.id
        preGestureFrame = card.worldFrame
    }

    // MARK: Stacking

    private func raiseToFront(_ card: CardView) {
        let maxZ = cards.values.map(\.worldFrame.z).max() ?? 0
        if card.worldFrame.z <= maxZ { card.worldFrame.z = maxZ + 1 }
        restack()
    }

    /// Orders subviews by world z (low → high = back → front).
    private func restack() {
        let ordered = cards.values.sorted { $0.worldFrame.z < $1.worldFrame.z }
        for card in ordered {
            card.removeFromSuperview()
            cardLayer.addSubview(card)
        }
    }

    // MARK: Projection

    private func reprojectAll() {
        for card in cards.values { reproject(card) }
    }

    private func reproject(_ card: CardView) {
        card.frame = worldToView(card.worldFrame.rect)
        // Terminal cards render at the card's view size; when zoom ≠ ~100% the
        // body is scaled via the layer transform (interactive only near 100% —
        // acceptable per the plan). The card frame already carries the scale,
        // and the embedded SwiftTerm view reflows on commit, so no extra layer
        // transform is needed here for the common case.
    }

    // MARK: - Pan / zoom gestures (crib §5)

    /// Pan via scrollWheel / two-finger trackpad. Precise-delta (trackpad)
    /// scrolls in pixels; legacy wheel lines are scaled up. Pan commits on
    /// every event (cheap; persistence is debounced by the caller if needed).
    override func scrollWheel(with event: NSEvent) {
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dxView = event.scrollingDeltaX * scale
        let dyView = event.scrollingDeltaY * scale
        // Dragging content right (positive deltaX) moves the world center left.
        viewport.cx -= dxView / viewport.zoom
        viewport.cy -= dyView / viewport.zoom
        reprojectAll()
        needsDisplay = true
        onLayoutChanged?(viewport)
    }

    /// Pinch magnify, anchored at the pointer (crib §5).
    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        let factor = 1 + event.magnification
        // Commit on gesture end only (phase == .ended); intermediate frames just
        // reproject for a smooth pinch.
        let commit = event.phase.contains(.ended) || event.momentumPhase.contains(.ended)
        zoom(by: factor, anchorViewPoint: anchor, commit: commit)
    }

    // MARK: - Grid

    private var loZoom = false

    private func updateGridDensity() {
        let lo = viewport.isSemanticZoom
        if lo != loZoom { loZoom = lo; needsDisplay = true }
    }

    override func layout() {
        super.layout()
        reprojectAll()
        needsDisplay = true
    }

    /// Dot grid drawn in board space: a world lattice at `spacing` (phased by
    /// `gridPhase`), each lattice point a `~2px` dot, projected to view. Spacing
    /// is the world step → view step is `spacing·zoom`. Below the semantic-zoom
    /// threshold the world spacing tightens to 11px (denser grid).
    override func draw(_ dirtyRect: NSRect) {
        Theme.bg0.setFill()
        dirtyRect.fill()

        let worldSpacing = loZoom ? Self.gridSpacingLo : Self.gridSpacing
        let viewSpacing = worldSpacing * viewport.zoom
        // Skip when dots would be denser than ~3px on screen (unreadable / slow).
        guard viewSpacing >= 3 else { return }

        // First lattice point ≥ the visible top-left, in world space.
        let topLeftWorld = viewToWorld(CGPoint(x: bounds.minX, y: bounds.minY))
        let bottomRightWorld = viewToWorld(CGPoint(x: bounds.maxX, y: bounds.maxY))
        let startKX = floor((topLeftWorld.x - Self.gridPhase.x) / worldSpacing)
        let startKY = floor((topLeftWorld.y - Self.gridPhase.y) / worldSpacing)
        let endKX = ceil((bottomRightWorld.x - Self.gridPhase.x) / worldSpacing)
        let endKY = ceil((bottomRightWorld.y - Self.gridPhase.y) / worldSpacing)

        Self.dotColor.setFill()
        let r = Self.dotRadius
        var ky = startKY
        while ky <= endKY {
            let worldY = Self.gridPhase.y + ky * worldSpacing
            var kx = startKX
            while kx <= endKX {
                let worldX = Self.gridPhase.x + kx * worldSpacing
                let v = worldToView(CGPoint(x: worldX, y: worldY))
                let dot = NSRect(x: v.x - r, y: v.y - r, width: r * 2, height: r * 2)
                if dirtyRect.intersects(dot) {
                    NSBezierPath(ovalIn: dot).fill()
                }
                kx += 1
            }
            ky += 1
        }
    }
}
