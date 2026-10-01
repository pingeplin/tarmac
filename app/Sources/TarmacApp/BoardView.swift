import AppKit
import QuartzCore
import TarmacKit

/// The board: an infinite, pannable, zoomable surface that places each card
/// by its world frame.
///
/// `view = (world − center)·zoom + viewportCenter`, where `center` is the
/// viewport's world-space center and `viewportCenter` the midpoint of this
/// view. Both spaces are top-down, and every card is reprojected on each pan,
/// zoom and layout. The surface itself is a flat fill.
@MainActor
final class BoardView: NSView {
    // MARK: - Callbacks

    /// Fires when something that is persisted changed: a card's frame or
    /// stacking, or the viewport. The listener debounces.
    var onLayoutChanged: ((Viewport) -> Void)?

    /// Fires on every viewport change, including each frame of a fly, for the
    /// chrome that tracks the viewport: zoom readout, minimap, offscreen hints.
    var onViewportChanged: ((Viewport) -> Void)?

    /// Fires when the card set, a card's frame or a card's signal changes, for
    /// the chrome derived from the cards.
    var onCardsChanged: (() -> Void)?

    /// Fires when a doc card's ✕ is clicked. Removing the card is the
    /// listener's call, since it also owns what closing a doc means.
    var onCardClose: ((CardID) -> Void)?

    /// Fires when a doc card's ↻ is clicked.
    var onCardRefresh: ((CardID) -> Void)?

    /// Fires when a card is culled or comes back, with whether it is now
    /// visible — once when the card is first placed and then on each flip. A
    /// culled card is hidden but alive; this is the cue to pause work that only
    /// matters on screen.
    var onCullChanged: ((CardID, _ visible: Bool) -> Void)?

    // MARK: - Cards

    private(set) var viewport: Viewport = .default

    /// Every card by id. Stacking follows each card's `z`, not this order.
    private(set) var cards: [CardID: CardView] = [:]

    /// Adds a card at its world frame, replacing any card with the same id.
    @discardableResult
    func addCard(id: CardID, worldFrame: CardFrame) -> CardView {
        removeCard(id: id)
        let card = CardView(id: id, worldFrame: worldFrame)
        wire(card)
        cards[id] = card
        cardLayer.addSubview(card)
        restack()
        reproject(card)
        card.applyContentScale(contentScale)
        card.applyBoardZoom(viewport.zoom)
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

    /// A card's bell or live signal changed.
    func signalsChanged() {
        onCardsChanged?()
    }

    func card(_ id: CardID) -> CardView? { cards[id] }

    /// Puts `view` in the terminal card for `termID`, creating the card if
    /// there is none. An existing card takes `worldFrame`, so a restore that
    /// finds the card already built still applies its persisted geometry.
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

    // MARK: - World and view

    func worldToView(_ p: CGPoint) -> CGPoint {
        BoardTransform.worldToView(
            p,
            zoom: viewport.zoom,
            center: CGPoint(x: viewport.cx, y: viewport.cy),
            viewportCenter: viewportCenter
        )
    }

    func viewToWorld(_ p: CGPoint) -> CGPoint {
        BoardTransform.viewToWorld(
            p,
            zoom: viewport.zoom,
            center: CGPoint(x: viewport.cx, y: viewport.cy),
            viewportCenter: viewportCenter
        )
    }

    func worldToView(_ r: CGRect) -> CGRect {
        let origin = worldToView(CGPoint(x: r.minX, y: r.minY))
        return CGRect(x: origin.x, y: origin.y, width: r.width * viewport.zoom, height: r.height * viewport.zoom)
    }

    /// The part of the world that is on screen.
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

    var minimapItems: [Minimap.Item] {
        cards.values.map { Minimap.Item(worldRect: $0.worldFrame.rect, signal: $0.signal) }
    }

    // MARK: - Viewport

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

    /// Centers on the bounding box of every card with a 10 % margin a side.
    /// Does nothing on an empty board.
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

    // MARK: - Selection and stacking

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
        onViewportChanged?(viewport)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor
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
            card.attached = false
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

    // MARK: Projection

    /// Reprojects every card. It does not announce a card change: it runs on
    /// every pan and zoom frame, where the card set is the same and the caller
    /// already announces the viewport.
    private func reprojectAll() {
        for card in cards.values { project(card) }
        updateContentScaleIfNeeded()
        recomputeEdges()
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

    /// One provenance edge per doc card whose owning terminal card is on the
    /// board, rebuilt from the cards' on-screen frames.
    func recomputeEdges() {
        var built: [Provenance.Segment] = []
        for (id, card) in cards {
            guard case .doc = id, let owner = card.ownerTermID, let ownerCard = cards[owner] else { continue }
            built.append(Provenance.edge(owner: ownerCard.frame, doc: card.frame))
        }
        edgeLayer.setEdges(built)
    }

    // MARK: Content scale

    /// A card is drawn at its world size and scaled to its frame, so above
    /// 100 % its backing store would be stretched. Each card's layers are
    /// rasterised at the backing scale times the zoom instead, capped at 3×; at
    /// or below 100 % the backing scale alone is kept and the card is scaled
    /// down. Re-applied only when the zoom changes, not on a pan.
    private var lastContentScaleZoom: CGFloat = 0
    private static let maxContentScaleZoom: CGFloat = 3
    private var contentScale: CGFloat {
        (window?.backingScaleFactor ?? 2) * max(1, min(viewport.zoom, Self.maxContentScaleZoom))
    }

    private func updateContentScaleIfNeeded() {
        guard window != nil, abs(viewport.zoom - lastContentScaleZoom) > 0.0001 else { return }
        lastContentScaleZoom = viewport.zoom
        let scale = contentScale
        for card in cards.values {
            card.applyContentScale(scale)
            card.applyBoardZoom(viewport.zoom)
        }
    }

    /// The window moved to a display of another density: the content scale and
    /// the device-pixel grid the cards are snapped to have both changed.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lastContentScaleZoom = 0
        reprojectAll()
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

    // MARK: - View

    /// The board has no keys of its own. Left unanswered, a key pressed while
    /// it holds keyboard focus would run off the end of the responder chain,
    /// and the window beeps for that.
    override func keyDown(with event: NSEvent) {}

    /// A new board size moves the visible region, so the cards are reprojected
    /// and the chrome that tracks the viewport is told.
    override func layout() {
        super.layout()
        reprojectAll()
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
