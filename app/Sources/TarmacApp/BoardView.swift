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
/// on every pan / zoom / layout. Hosted by `RootView` in place of the retired
/// `DeskGridView`.
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

    /// Fires on EVERY viewport change (pan / zoom / restore / fit / fly), not
    /// just commits — the wayfinding chrome (zoom readout, minimap, offscreen
    /// hints) refreshes off this so it tracks the live viewport. Cheap; no
    /// persistence here (that's `onLayoutChanged`).
    var onViewportChanged: ((Viewport) -> Void)?

    /// Fires whenever the card set or any card's world frame / signal changes,
    /// so the wayfinding chrome rebuilds its card-derived state (minimap rects,
    /// offscreen hints). The board calls this after add / remove / reproject.
    var onCardsChanged: (() -> Void)?

    /// Current viewport (zoom + world center). Read for persistence; set by 2c
    /// from `restore.board` to reproduce the saved viewport.
    private(set) var viewport: Viewport = .default

    /// All cards by id, in no particular order (z drives stacking).
    private(set) var cards: [CardID: CardView] = [:]

    /// Per-doc-card provenance edge label (crib §8: `tarmac open · HH:MM`).
    /// AppController supplies it (HH:MM from the doc's lastOpenedMs, local) since
    /// the board has no doc registry. Returning nil draws the edge without a chip.
    var edgeLabelProvider: ((CardID) -> String?)?

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
        // Locards (semantic-zoom summaries) are off: in the infinite-canvas model
        // a zoomed-out card shows its real content scaled down (the reference
        // behavior), not a fixed-size name+status swap. `setLocard` stays wired so
        // the feature can return as an explicit, counter-scaled overview later.
        card.setLocard(false)
        reproject(card)
        card.applyContentScale(contentScale)
        onCardsChanged?()
        return card
    }

    func removeCard(id: CardID) {
        guard let card = cards.removeValue(forKey: id) else { return }
        if selectedID == id { selectedID = nil }
        card.removeFromSuperview()
        recomputeEdges()
        onCardsChanged?()
    }

    /// The board's signals changed on a card (Phase 3.5 bell / Phase 4 live);
    /// callers route signal updates through here so the wayfinding chrome
    /// refreshes (minimap colors, offscreen hints). Cheap.
    func signalsChanged() {
        onCardsChanged?()
    }

    func card(_ id: CardID) -> CardView? { cards[id] }

    /// Ensures a terminal card for `termID` exists at `worldFrame` and attaches
    /// the SwiftTerm view into its body (Phase 5b: one card per `term_id`). On
    /// restore the card may already exist, so its world frame is *re-applied*
    /// here — otherwise persisted move/resize geometry is silently dropped and
    /// the terminal snaps back to its init frame.
    func setTerminal(termID: String, _ view: NSView, worldFrame: CardFrame) {
        let card: CardView
        if let existing = cards[.term(termID)] {
            existing.worldFrame = worldFrame
            reproject(existing)
            restack()
            card = existing
        } else {
            card = addCard(id: .term(termID), worldFrame: worldFrame)
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
        updateLocards()
        needsDisplay = true
        onViewportChanged?(viewport)
        if commit { onLayoutChanged?(viewport) }
    }

    /// Animates the viewport to `vp` (crib §6: ⏎ flies to a card near 100%, esc
    /// flies back). Instant under Reduce Motion. Always commits at the end so
    /// the flown-to viewport persists.
    func flyTo(_ vp: Viewport) {
        let target = clampZoom(vp)
        if Theme.reduceMotion {
            setViewport(target, commit: true)
            return
        }
        animateViewport(to: target) { [weak self] in
            self?.onLayoutChanged?(target)
        }
    }

    /// Fly the viewport to center `cardID` near 100% (crib §6 Return flight).
    func fly(to cardID: CardID) {
        guard let card = cards[cardID] else { return }
        let f = card.worldFrame
        let zoom = min(Viewport.maxZoom, max(Viewport.minZoom, 1.0))
        flyTo(Viewport(zoom: zoom, cx: f.x + f.w / 2, cy: f.y + f.h / 2))
    }

    /// Fit all card world frames into view with margin (crib §6 ⊡ fit), then
    /// commit. No-op when there are no cards.
    func fitToCards(commit: Bool = true) {
        let rects = cards.values.map(\.worldFrame.rect)
        guard let fit = BoardWayfinding.fit(
            cards: rects,
            viewportSize: bounds.size,
            margin: 0.1,
            minZoom: Viewport.minZoom,
            maxZoom: Viewport.maxZoom
        ) else { return }
        setViewport(Viewport(zoom: fit.zoom, cx: fit.center.x, cy: fit.center.y), commit: commit)
    }

    /// The currently-visible region in WORLD coordinates (the inverse-projected
    /// view bounds) — fed to the minimap (viewport rect) and offscreen hints.
    var viewportWorldRect: CGRect {
        let topLeft = viewToWorld(CGPoint(x: bounds.minX, y: bounds.minY))
        let bottomRight = viewToWorld(CGPoint(x: bounds.maxX, y: bounds.maxY))
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    /// All cards' world frames + signals, for the minimap.
    var minimapItems: [Minimap.Item] {
        cards.values.map { Minimap.Item(worldRect: $0.worldFrame.rect, signal: $0.signal) }
    }

    private func animateViewport(to target: Viewport, completion: @escaping () -> Void) {
        let start = viewport
        let steps = 18
        var frame = 0
        let ease = { (t: CGFloat) -> CGFloat in t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
        func tick() {
            frame += 1
            let t = ease(CGFloat(frame) / CGFloat(steps))
            let vp = Viewport(
                zoom: start.zoom + (target.zoom - start.zoom) * t,
                cx: start.cx + (target.cx - start.cx) * t,
                cy: start.cy + (target.cy - start.cy) * t
            )
            viewport = clampZoom(vp)
            reprojectAll()
            updateGridDensity()
            updateLocards()
            needsDisplay = true
            onViewportChanged?(viewport)
            if frame < steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) {
                    MainActor.assumeIsolated { tick() }
                }
            } else {
                completion()
            }
        }
        tick()
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
        updateLocards()
        needsDisplay = true
        onViewportChanged?(viewport)
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

    /// True while a card move/resize is in flight — the controller suppresses
    /// board zoom during a gesture so the cached `worldPerView` (pointer→world
    /// scale, snapshot at gesture start) can't go stale mid-drag.
    var isGesturing: Bool { gesturingID != nil }

    /// Raises `id` to the front WITHOUT selecting it (no resize handles). Used by
    /// click-to-focus (point 3): a clicked card comes forward, but the handles
    /// stay reserved for an explicit move/resize grab on the header.
    func bringToFront(_ id: CardID) {
        guard let card = cards[id] else { return }
        raiseToFront(card)
    }

    /// esc drag-cancel priority (crib §5): cancels an in-flight move/resize and
    /// restores the pre-gesture world frame. Returns false when no card is
    /// dragging so esc falls through to peek/toast dismissal.
    @discardableResult
    func cancelDrag() -> Bool {
        guard let id = gesturingID, let card = cards[id] else { return false }
        let restored = card.cancelGesture(restoringTo: preGestureFrame)
        if restored {
            // Restore any satellites that were dragged along by gravity.
            for (satID, anchor) in satelliteAnchors {
                guard let sat = cards[satID] else { continue }
                sat.worldFrame = anchor
                sat.frame = worldToView(sat.worldFrame.rect)
            }
            satelliteAnchors = [:]
            reproject(card)
            gesturingID = nil
            preGestureFrame = nil
        }
        return restored
    }

    // MARK: - Cockpit dock (crib §4): slot ghost at the docked term card's spot

    /// While a card is docked into the cockpit pane its board card is hidden and
    /// a dashed slot ghost (crib §4 `.tm-slotghost`) sits at its world frame so
    /// the board still shows where it belongs; the ghost pans/zooms with the
    /// board. nil when nothing is docked.
    private var dockedID: CardID?
    private let slotGhost = SlotGhostView()

    /// Marks `id`'s card as docked: hide its board card and show the slot ghost
    /// at its world frame (crib §4). The card stays in `cards` (its world frame
    /// is preserved for undock + persistence) but is not displayed. Pass nil to
    /// clear the dock (un-dock): the card reappears, the ghost is removed.
    func setDocked(_ id: CardID?) {
        // Restore any previously-docked card.
        if let prev = dockedID, let card = cards[prev] {
            card.isHidden = false
        }
        slotGhost.removeFromSuperview()
        dockedID = id
        guard let id, let card = cards[id] else { return }
        card.isHidden = true
        slotGhost.frame = worldToView(card.worldFrame.rect)
        cardLayer.addSubview(slotGhost, positioned: .below, relativeTo: nil)
    }

    /// Keeps the slot ghost on the docked card's reprojected frame (pan/zoom).
    private func reprojectSlotGhost() {
        guard let id = dockedID, let card = cards[id] else { return }
        slotGhost.frame = worldToView(card.worldFrame.rect)
    }

    // MARK: - Internals

    private let cardLayer = FlippedColumnView()
    private let edgeLayer = EdgeLayerView()
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
        // Edge layer is backmost (crib §8: beneath the cards, z 0).
        edgeLayer.frame = bounds
        edgeLayer.autoresizingMask = [.width, .height]
        addSubview(edgeLayer)
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
            // terminal once on resize end). A term-card move drags its attached
            // satellites along (gravity, crib §5).
            guard let self else { return }
            self.translateSatellitesDuringGesture(of: c)
            self.reproject(c)
        }
        card.onFrameCommitted = { [weak self] c in
            guard let self else { return }
            self.commitGravity(for: c)
            self.gesturingID = nil
            self.preGestureFrame = nil
            self.satelliteAnchors = [:]
            self.reproject(c)
            self.onLayoutChanged?(self.viewport)
        }
    }

    private func beginGesture(on card: CardView) {
        card.worldPerView = 1 / viewport.zoom
        gesturingID = card.id
        preGestureFrame = card.worldFrame
        // Snapshot the attached satellites of a term card so a move can
        // translate them by the same world delta (gravity, crib §5).
        satelliteAnchors = [:]
        if case .term = card.id {
            for (id, c) in cards where c.ownerTermID == card.id && c.attached {
                satelliteAnchors[id] = c.worldFrame
            }
        }
    }

    /// Pre-gesture world frames of the gesturing term card's attached satellites.
    private var satelliteAnchors: [CardID: CardFrame] = [:]

    /// Translates the gesturing term card's attached satellites by the same
    /// world delta as the term card has moved so far (gravity; crib §5).
    private func translateSatellitesDuringGesture(of card: CardView) {
        guard case .term = card.id, let start = preGestureFrame, !satelliteAnchors.isEmpty else { return }
        let dx = card.worldFrame.x - start.x
        let dy = card.worldFrame.y - start.y
        guard dx != 0 || dy != 0 else { return }
        for (id, anchor) in satelliteAnchors {
            guard let sat = cards[id] else { continue }
            sat.worldFrame.x = anchor.x + dx
            sat.worldFrame.y = anchor.y + dy
            sat.frame = worldToView(sat.worldFrame.rect)
        }
    }

    /// Gravity bookkeeping at commit (crib §5): a USER move of a doc card
    /// detaches it (loose); a term-card move's translated satellites are already
    /// in place. Resizes never touch gravity.
    private func commitGravity(for card: CardView) {
        guard card.lastCommittedGestureWasMove else { return }
        if case .doc = card.id, card.attached {
            card.attached = false
            card.setOwnerChip(nil)
        }
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
        for card in cards.values { project(card) }
        updateContentScaleIfNeeded()
        reprojectSlotGhost()
        recomputeEdges()
        onCardsChanged?()
    }

    /// The card layer is scaled as a bitmap by the `frame≠bounds` transform, so
    /// zooming IN past 100% would upscale a backing store rendered at the normal
    /// screen resolution → blur. Counter it by rendering each card's content at
    /// `backingScale × zoom` resolution (capped) when zoomed in, so the upscale
    /// has real pixels. Zoom-out keeps the default scale (downscaling is already
    /// crisp). Re-applied only when the zoom actually changes (not on every pan).
    private var lastContentScaleZoom: CGFloat = 0
    private var contentScale: CGFloat {
        (window?.backingScaleFactor ?? 2) * max(1, min(viewport.zoom, Self.maxContentScaleZoom))
    }
    private static let maxContentScaleZoom: CGFloat = 3

    private func updateContentScaleIfNeeded() {
        guard window != nil, abs(viewport.zoom - lastContentScaleZoom) > 0.0001 else { return }
        lastContentScaleZoom = viewport.zoom
        let scale = contentScale
        for card in cards.values { card.applyContentScale(scale) }
    }

    private func reproject(_ card: CardView) {
        project(card)
        reprojectSlotGhost()
        recomputeEdges()
        onCardsChanged?()
    }

    /// Places a card on screen (infinite-canvas model). The card's on-screen
    /// FRAME carries the world→view position *and* the zoom scale, but its
    /// internal BOUNDS stay the card's intrinsic *world* size. AppKit realizes
    /// the frame≠bounds size difference as a uniform scale on the card's layer
    /// tree — so the card and everything it hosts (the SwiftTerm grid, the doc
    /// webview, chrome) scale as a single unit and the content layout never
    /// re-flows from a zoom. Only a card RESIZE changes the world size (`bounds`),
    /// which is the one time the terminal re-measures its cols/rows. Zoom is thus
    /// a pure view transform, matching the Heptabase/Figma canvas feel.
    private func project(_ card: CardView) {
        card.frame = worldToView(card.worldFrame.rect)
        card.setBoundsSize(CGSize(width: card.worldFrame.w, height: card.worldFrame.h))
    }

    /// Rebuilds the provenance edge set in view space (crib §8): one edge per
    /// doc card whose owning term card is present. Called on every reproject so
    /// edges survive pan / zoom / drag.
    func recomputeEdges() {
        var built: [EdgeLayerView.Edge] = []
        for (id, card) in cards {
            guard case .doc = id, let owner = card.ownerTermID, let ownerCard = cards[owner] else { continue }
            built.append(EdgeLayerView.Edge(
                callerRect: ownerCard.frame,
                docRect: card.frame,
                label: edgeLabelProvider?(id)
            ))
        }
        edgeLayer.setEdges(built)
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
        onViewportChanged?(viewport)
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

    /// No-op in the infinite-canvas model — cards always render their real
    /// (zoom-scaled) content rather than swapping to a fixed-size locard at the
    /// semantic-zoom threshold. See `addCard`. Kept (and still called on zoom
    /// crossings) so the feature can return as an explicit counter-scaled overview.
    func updateLocards() {
        for card in cards.values { card.setLocard(false) }
    }

    override func layout() {
        super.layout()
        reprojectAll()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The real backing scale is only known once attached to a window; force
        // the content-scale to re-apply (the zoom-guard would otherwise skip it).
        lastContentScaleZoom = 0
        updateContentScaleIfNeeded()
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
