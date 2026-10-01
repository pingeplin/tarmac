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

    /// Fires when a doc card's ✕ close button is clicked. Kept separate from
    /// `removeCard` (the mechanical teardown) so the controller owns the
    /// persistence policy.
    var onCardClose: ((CardID) -> Void)?

    /// Fires when a doc card's ↻ button is clicked.
    var onCardRefresh: ((CardID) -> Void)?

    /// Fires when a card is culled or comes back, with whether it is now
    /// visible — once when the card is first placed and then on each flip. A
    /// culled card is hidden but alive; this is the cue to pause work that only
    /// matters on screen.
    var onCullChanged: ((CardID, _ visible: Bool) -> Void)?

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
        reproject(card)
        card.applyContentScale(contentScale)       // in-process layers
        card.applyDocZoomScale(docDeviceScaleOverride)  // a fresh doc card starts at the right density
        onCardsChanged?()
        return card
    }

    func removeCard(id: CardID) {
        guard let card = cards.removeValue(forKey: id) else { return }
        culls.forget(id)
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
    /// the terminal view into its body (Phase 5b: one card per `term_id`). On
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

    /// Jumps the viewport to `vp`, clamping its zoom. Any fly in flight stops
    /// here. `commit` also reports the change for persistence.
    func setViewport(_ vp: Viewport, commit: Bool = false) {
        flight.cancel()
        show(vp)
        if commit { onLayoutChanged?(viewport) }
    }

    /// Flies the viewport to `vp` over 300 ms, or jumps there under Reduce
    /// Motion. A pan, a zoom, a `setViewport` or another fly interrupts it and
    /// leaves the viewport where it had got to; only a fly that lands is
    /// reported for persistence.
    func flyTo(_ vp: Viewport) {
        let target = clampZoom(vp)
        if Theme.reduceMotion {
            setViewport(target, commit: true)
            return
        }
        flight.start(
            BoardFly(from: viewport.wire, to: target.wire),
            onFrame: { [weak self] frame in self?.show(Viewport(frame)) },
            onLanding: { [weak self] in
                guard let self else { return }
                self.onLayoutChanged?(self.viewport)
            }
        )
    }

    /// Flies to `cardID`'s center at zoom 1.
    func fly(to cardID: CardID) {
        guard let card = cards[cardID] else { return }
        let f = card.worldFrame
        flyTo(Viewport(zoom: 1, cx: f.x + f.w / 2, cy: f.y + f.h / 2))
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

    /// Multiplies the zoom by `factor`, keeping the world point under
    /// `anchorViewPoint` (the board's center by default) where it is on screen.
    func zoom(by factor: CGFloat, anchorViewPoint: CGPoint? = nil, commit: Bool) {
        flight.cancel()
        let anchor = anchorViewPoint ?? viewportCenter
        let worldAnchor = viewToWorld(anchor)
        let newZoom = clampValue(viewport.zoom * factor)
        if newZoom != viewport.zoom {
            let c = viewportCenter
            show(Viewport(
                zoom: newZoom,
                cx: worldAnchor.x - (anchor.x - c.x) / newZoom,
                cy: worldAnchor.y - (anchor.y - c.y) / newZoom
            ))
        }
        if commit { onLayoutChanged?(viewport) }
    }

    /// The one selected card: it wears the ring and its body takes the wheel.
    /// Only a board that is on screen can hold a selection, so a card set
    /// up on a background board never arrives already selected.
    private(set) var selectedID: CardID?

    /// Selects `id`, or clears the selection with nil. Selecting never
    /// reorders cards — `raise` does that.
    func select(_ id: CardID?) {
        let id = window == nil ? nil : id.flatMap { cards[$0] == nil ? nil : $0 }
        guard id != selectedID else { return }
        if let previous = selectedID { cards[previous]?.setSelected(false) }
        selectedID = id
        if let id { cards[id]?.setSelected(true) }
    }

    /// Puts `id` above every card on the board, even if it is already on top.
    func raise(_ id: CardID) {
        guard let card = cards[id] else { return }
        card.worldFrame.z = ZOrder.raised(above: cards.values.map(\.worldFrame.z))
        restack()
        onLayoutChanged?(viewport)
    }

    // MARK: - Internals

    private let cardLayer = CardLayerView()
    private let edgeLayer = EdgeLayerView()
    /// Set while a terminal card is being moved by its header.
    private var carry: SatelliteCarry?
    private let cursors = HoverCursorRouter()
    private let flight = ViewportFlight()
    private var culls = CullLedger<CardID>()
    private var pointerTracking: NSTrackingArea?

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

    /// The one place the viewport changes: every card is reprojected and the
    /// chrome that tracks the viewport is told.
    private func show(_ vp: Viewport) {
        viewport = clampZoom(vp)
        reprojectAll()
        updateGridDensity()
        needsDisplay = true
        onViewportChanged?(viewport)
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
        card.onClose = { [weak self] c in self?.onCardClose?(c.id) }
        card.onRefresh = { [weak self] c in self?.onCardRefresh?(c.id) }
        card.onMoveBegan = { [weak self] c in self?.beginCarry(for: c) }
        card.onFrameChanging = { [weak self] c in
            guard let self else { return }
            self.carrySatellites(of: c)
            self.reproject(c)
        }
        card.onGestureEnded = { [weak self] c, outcome in self?.endGesture(on: c, outcome: outcome) }
    }

    /// Only a completed move commits anything beyond the frame itself: it
    /// detaches a doc from its owner and drops its fresh mark. A click and a
    /// resize leave both alone.
    private func endGesture(on card: CardView, outcome: CardGesture.Outcome) {
        if outcome == .move, case .doc = card.id {
            card.setFresh(false)
            if card.attached {
                card.attached = false
                card.setOwnerChip(nil)
            }
        }
        carry = nil
        reproject(card)
        onLayoutChanged?(viewport)
    }

    // MARK: Gravity

    /// A terminal card's attached docs as they stood when its header was
    /// pressed. Only a header move carries them: a resize from the left or top
    /// also shifts the terminal's origin, and must leave its docs where they are.
    private struct SatelliteCarry {
        let ownerStart: CardFrame
        let anchors: [CardID: CardFrame]
    }

    private func beginCarry(for card: CardView) {
        guard case .term = card.id else { return }
        let attached = cards.filter { $0.value.ownerTermID == card.id && $0.value.attached }
        carry = SatelliteCarry(ownerStart: card.worldFrame, anchors: attached.mapValues(\.worldFrame))
    }

    private func carrySatellites(of card: CardView) {
        guard let carry else { return }
        let dx = card.worldFrame.x - carry.ownerStart.x
        let dy = card.worldFrame.y - carry.ownerStart.y
        for (id, anchor) in carry.anchors {
            guard let satellite = cards[id] else { continue }
            satellite.worldFrame.x = anchor.x + dx
            satellite.worldFrame.y = anchor.y + dy
            project(satellite)
        }
    }

    // MARK: Stacking

    /// Orders subviews by world z (low → high = back → front). Sorted in place:
    /// taking a card out of the hierarchy to re-add it resigns the window's
    /// first responder inside it, severs a press in flight, and reloads a web
    /// view.
    private func restack() {
        cardLayer.sortSubviews({ a, b, _ in
            MainActor.assumeIsolated {
                let za = (a as? CardView)?.worldFrame.z ?? 0
                let zb = (b as? CardView)?.worldFrame.z ?? 0
                return za < zb ? .orderedAscending : za > zb ? .orderedDescending : .orderedSame
            }
        }, context: nil)
    }

    // MARK: Projection

    private func reprojectAll() {
        PerfTrace.measure("reproject") {
            for card in cards.values { project(card) }
            updateContentScaleIfNeeded()
            recomputeEdges()
            // NB: no onCardsChanged?() here. reprojectAll runs on every pan/zoom,
            // where the card SET is unchanged and its callers already fire
            // onViewportChanged (→ one wayfinding refresh/frame). onCardsChanged
            // stays on the real set-mutation paths (add/remove/signals) and the
            // single-card drag reproject. Fix #3: was a redundant 2nd refresh/frame.
        }
        PerfTrace.gauge("visibleCards", visibleCardCount)
        PerfTrace.gauge("liveCards", cards.values.reduce(into: 0) { if !$1.isHidden { $0 += 1 } })
        PerfTrace.gauge("totalCards", cards.count)
    }

    /// Cards whose projected view frame intersects the board bounds (and that are
    /// actually shown). Instrumentation-only for now, but it doubles as the
    /// baseline metric — and a prototype of the predicate — for fix #5 (viewport
    /// culling): how many live subviews the compositor touches per frame.
    private var visibleCardCount: Int {
        cards.values.reduce(into: 0) { n, card in
            if !card.isHidden, card.frame.intersects(bounds) { n += 1 }
        }
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

    /// The device-scale override pushed to doc cards' WKWebViews. We *always*
    /// render the doc at ≥2× density. On a 1× external display, rendering at the
    /// display's native 1× makes WebKit's grayscale sans text look thin and
    /// feathered ("毛邊"); oversampling (render at 2×, the compositor downsamples
    /// to the 1× panel) gives smoother edges than native 1× can. On a 2× Retina
    /// display the floor is a no-op. Above 100% it tracks `backingScale × zoom`
    /// (capped) so the frame≠bounds upscale stays crisp. Always non-zero, so
    /// WebKit's own auto-tracking stays off — `viewDidChangeBackingProperties`
    /// re-asserts the value when the window crosses to a different-density screen.
    private var docDeviceScaleOverride: CGFloat {
        let backing = window?.backingScaleFactor ?? 2
        let zoomFactor = min(max(viewport.zoom, 1), Self.maxContentScaleZoom)
        return max(2, backing * zoomFactor)
    }

    private func updateContentScaleIfNeeded() {
        guard window != nil, abs(viewport.zoom - lastContentScaleZoom) > 0.0001 else { return }
        lastContentScaleZoom = viewport.zoom
        let scale = contentScale
        let docOverride = docDeviceScaleOverride
        for card in cards.values {
            card.applyContentScale(scale)          // in-process layers: terminal grid, chrome
            card.applyDocZoomScale(docOverride)     // out-of-process WebKit tiles (doc cards)
        }
    }

    /// The window moved to a display of another density: the content scale and
    /// the device-pixel grid the cards are snapped to have both changed.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lastContentScaleZoom = 0
        reprojectAll()
    }

    private func reproject(_ card: CardView) {
        project(card)
        recomputeEdges()
        onCardsChanged?()
    }

    /// Places a card on screen. Its frame carries the position and the zoom
    /// while its bounds stay the card's world size, so AppKit scales the card and
    /// everything in it as one and its content never reflows under zoom: only a
    /// resize changes the world size, which is the one time a terminal
    /// re-measures its grid.
    private func project(_ card: CardView) {
        let frame = screenFrame(of: card.worldFrame.rect)
        let resized = card.frame.size != frame.size
        card.frame = frame
        // A new frame size drags the bounds along with it, so they are put back
        // to the world size on a zoom step or a resize. A pan leaves them alone.
        if resized { card.setBoundsSize(CGSize(width: card.worldFrame.w, height: card.worldFrame.h)) }
        cull(card)
    }

    /// A world rect's place on screen, with its origin moved to the nearest
    /// whole device pixel. An origin between pixels has the whole card
    /// resampled, which softens every glyph and hairline in it — plainly so on a
    /// 1× display. The size is left alone: it is what carries the zoom.
    private func screenFrame(of world: CGRect) -> CGRect {
        let raw = worldToView(world)
        let aligned = cardLayer.backingAlignedRect(
            raw, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
        )
        return CGRect(origin: aligned.origin, size: raw.size)
    }

    /// Hides a card that lies more than a viewport off screen and shows it
    /// again a full viewport before it scrolls into view. The card stays in the
    /// hierarchy either way, so a terminal keeps taking output and a doc keeps
    /// its scroll. A board that is not in a window has no viewport, and every
    /// card on it is culled.
    private func cull(_ card: CardView) {
        let visible = Cull.isCardVisible(
            frame: card.worldFrame.rect,
            zoom: viewport.zoom,
            center: CGPoint(x: viewport.cx, y: viewport.cy),
            viewSize: window == nil ? .zero : bounds.size
        )
        guard culls.record(card.id, visible: visible) else { return }
        card.isHidden = !visible
        onCullChanged?(card.id, visible)
    }

    /// Rebuilds the provenance edge set in view space (crib §8): one edge per
    /// doc card whose owning term card is present. Called on every reproject so
    /// edges survive pan / zoom / drag.
    func recomputeEdges() {
        PerfTrace.measure("edges") {
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
    }

    // MARK: - Perf benchmark (perf/whiteboard-profiling; removable)

    /// Deterministically sweeps the board through `levels` zoom factors, panning
    /// `iterations` steps at each and forcing a synchronous dot-grid redraw, so
    /// PerfTrace captures a per-level baseline with no GUI interaction (synthetic
    /// trackpad/pinch events get dropped without an Accessibility grant). Drives
    /// `reprojectAll()` directly, never `onLayoutChanged`, so the sweep persists
    /// nothing (the persist-coalescing check lives in AppController, fix #2).
    /// Removable with PerfTrace — see docs/perf-whiteboard-zoom.md.
    func runBenchmark(iterations: Int, levels: [CGFloat]) {
        populateBenchmarkCards()
        // Warm up: the first draws allocate the layer backing store and the
        // NSBezierPath machinery — discard those so they don't skew level 1.
        viewport = Viewport(zoom: 1.0, cx: 0, cy: 0)
        updateGridDensity()
        for _ in 0..<12 { viewport.cx += 7; reprojectAll(); display() }
        PerfTrace.flush("warmup(discard)")

        for z in levels {
            viewport = Viewport(zoom: z, cx: 0, cy: 0)
            updateGridDensity()         // flip the 24↔11px grid at the 0.5 threshold
            for _ in 0..<iterations {
                viewport.cx += 7
                viewport.cy += 3
                // Mirror a real pan frame (scrollWheel): reproject, fire the
                // viewport-changed wayfinding refresh, then redraw. onLayoutChanged
                // (persist) is intentionally skipped so the sweep writes no layouts.
                reprojectAll()
                onViewportChanged?(viewport)
                display()               // forces draw(_:) — the dot grid — synchronously
            }
            PerfTrace.flush(String(format: "zoom=%.2f", z))
            captureBenchmarkSnapshot(zoom: z)
        }
    }

    /// Writes the rendered board (grid + cards) to `/tmp/tarmac-grid-z<zz>.png`
    /// so a rendering change (e.g. fix #1) can be visually regression-checked
    /// against the prior run, not just trusted to be faster.
    private func captureBenchmarkSnapshot(zoom: CGFloat) {
        viewport = Viewport(zoom: zoom, cx: 0, cy: 0)
        reprojectAll()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: String(format: "/tmp/tarmac-grid-z%.2f.png", zoom)))
    }

    /// Bare synthetic cards spread across world space (some on-screen, most off)
    /// so the benchmark's reproject / edge / visible-card costs are non-trivial
    /// and reproducible. No content is attached (no terminal/WKWebView), so the
    /// cards stay light; every other doc links to the term card so `recomputeEdges`
    /// rebuilds real edge geometry each frame. No-op if the board already has cards.
    private func populateBenchmarkCards() {
        let termID = "perf-bench-term"
        // Keyed on our own marker (not `cards.isEmpty`) — a daemon-less launch
        // still mounts one prime-terminal card, which would otherwise suppress
        // the whole synthetic set and leave totalCards == 1.
        guard cards[.term(termID)] == nil else { return }
        addCard(id: .term(termID), worldFrame: CardFrame(x: -400, y: -300, w: 360, h: 240, z: 0))
        var i = 0
        for ry in 0..<5 {
            for rx in 0..<8 {
                let card = addCard(
                    id: .doc("perf-bench-\(i)"),
                    worldFrame: CardFrame(x: CGFloat(rx) * 520 - 1400, y: CGFloat(ry) * 360 - 900, w: 360, h: 260, z: i + 1)
                )
                if i.isMultiple(of: 2) { card.ownerTermID = .term(termID) }
                i += 1
            }
        }
    }

    // MARK: - Pan and zoom

    /// A wheel pans by its delta in screen points; with control held it zooms
    /// about the pointer instead. A notched wheel reports lines, scaled up here.
    override func scrollWheel(with event: NSEvent) {
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale
        if event.modifierFlags.contains(.control) {
            // AppKit's delta has the opposite sign to the web's `deltaY`.
            zoom(by: BoardWheel.zoomFactor(deltaY: -dy), anchorViewPoint: convert(event.locationInWindow, from: nil), commit: true)
            return
        }
        flight.cancel()
        show(Viewport(zoom: viewport.zoom, cx: viewport.cx - dx / viewport.zoom, cy: viewport.cy - dy / viewport.zoom))
        onLayoutChanged?(viewport)
    }

    /// A pinch zooms about the pointer.
    override func magnify(with event: NSEvent) {
        zoom(
            by: BoardWheel.zoomFactor(magnification: event.magnification),
            anchorViewPoint: convert(event.locationInWindow, from: nil),
            commit: true
        )
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
        // A board-size change moves the visible region; refresh wayfinding via the
        // viewport channel (fix #3 removed reprojectAll's own onCardsChanged).
        onViewportChanged?(viewport)
    }

    /// Asks for pointer moves over the whole board, which the cursor router
    /// reads; without a tracking area the window sends none.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseExited(with event: NSEvent) {
        cursors.release()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cursors.attach(to: window)
        if window == nil { select(nil) }
        // The backing scale is only known in a window, so the content scale is
        // re-applied on arrival; and a board out of a window culls every card.
        lastContentScaleZoom = 0
        reprojectAll()
    }

    /// Dot grid drawn in board space: a world lattice at `spacing` (phased by
    /// `gridPhase`), each lattice point a `~2px` dot, projected to view. Spacing
    /// is the world step → view step is `spacing·zoom`. Below the semantic-zoom
    /// threshold the world spacing tightens to 11px (denser grid).
    ///
    /// Fix #1 (perf): the lattice is painted as ONE tiled blit of a cached
    /// single-dot tile — `CGContext.draw(_:in:byTiling:)` — rather than a fresh
    /// `NSBezierPath(ovalIn:).fill()` per dot. The old loop was O(dots) and at the
    /// 11px density (zoom < 0.5) rasterized 26k–79k anti-aliased circles per frame
    /// (~40–130ms on the main thread — the "50% cliff"). The tile's *period* is the
    /// exact (fractional) `viewSpacing` and its centered dot is anchored on a real
    /// lattice point, so every replica lands where the per-dot loop drew — visually
    /// identical, but the grid is now a single CoreGraphics tile fill.
    override func draw(_ dirtyRect: NSRect) {
        Theme.bg0.setFill()
        dirtyRect.fill()

        let worldSpacing = loZoom ? Self.gridSpacingLo : Self.gridSpacing
        let viewSpacing = worldSpacing * viewport.zoom
        // Skip when dots would be denser than ~3px on screen (unreadable / slow).
        guard viewSpacing >= 3, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // The lattice point at or before the visible top-left — the phase anchor.
        // CoreGraphics replicates the tile in BOTH directions from `tileRect`, so
        // seating one tile's centered dot on this point lands every replica on a
        // lattice point (the tiling period equals `viewSpacing`).
        let topLeftWorld = viewToWorld(CGPoint(x: bounds.minX, y: bounds.minY))
        let bottomRightWorld = viewToWorld(CGPoint(x: bounds.maxX, y: bounds.maxY))
        let startKX = floor((topLeftWorld.x - Self.gridPhase.x) / worldSpacing)
        let startKY = floor((topLeftWorld.y - Self.gridPhase.y) / worldSpacing)
        let endKX = ceil((bottomRightWorld.x - Self.gridPhase.x) / worldSpacing)
        let endKY = ceil((bottomRightWorld.y - Self.gridPhase.y) / worldSpacing)
        // Lattice size the grid covers — the count the old loop drew, kept as the
        // `gridDots` gauge so before/after baselines stay comparable.
        PerfTrace.gauge("gridDots", max(0, Int(endKX - startKX) + 1) * max(0, Int(endKY - startKY) + 1))

        let anchor = worldToView(CGPoint(x: Self.gridPhase.x + startKX * worldSpacing,
                                         y: Self.gridPhase.y + startKY * worldSpacing))
        let scale = window?.backingScaleFactor ?? 2
        let tile = gridTile(viewSpacing: viewSpacing, scale: scale)
        let tileRect = CGRect(x: anchor.x - viewSpacing / 2, y: anchor.y - viewSpacing / 2,
                              width: viewSpacing, height: viewSpacing)
        PerfTrace.measure("draw") {
            ctx.saveGState()
            ctx.clip(to: dirtyRect)
            ctx.draw(tile, in: tileRect, byTiling: true)
            ctx.restoreGState()
        }
    }

    /// Cached one-cell grid tile: a single centered dot on transparency, sized to
    /// `viewSpacing` at the backing `scale`. Keyed by pixel size, so it's rebuilt
    /// only when zoom or display density changes — never per pan frame. The image's
    /// pixel size affects only dot sharpness; the lattice period is the exact
    /// fractional `tileRect`, so rounding here never drifts the grid phase.
    private var gridTileCache: (pixelSize: Int, image: CGImage)?

    private func gridTile(viewSpacing: CGFloat, scale: CGFloat) -> CGImage {
        let px = max(1, Int((viewSpacing * scale).rounded()))
        if let cached = gridTileCache, cached.pixelSize == px { return cached.image }
        let image = Self.makeGridTile(pixelSize: px, dotRadiusPx: Self.dotRadius * scale, color: Self.dotColor)
        gridTileCache = (px, image)
        return image
    }

    private static func makeGridTile(pixelSize: Int, dotRadiusPx: CGFloat, color: NSColor) -> CGImage {
        let ctx = CGContext(
            data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if let rgb = color.usingColorSpace(.deviceRGB) {
            ctx.setFillColor(red: rgb.redComponent, green: rgb.greenComponent,
                             blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        }
        let c = CGFloat(pixelSize) / 2
        ctx.fillEllipse(in: CGRect(x: c - dotRadiusPx, y: c - dotRadiusPx, width: dotRadiusPx * 2, height: dotRadiusPx * 2))
        return ctx.makeImage()!
    }
}

/// Holds the cards. Between cards it is not there: a press on the bare board
/// lands on the `BoardView` itself, which takes keyboard focus for it.
@MainActor
private final class CardLayerView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
