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
    private var cardsAdded = 0

    /// Adds a card at its world frame, replacing any card with the same id.
    @discardableResult
    func addCard(id: CardID, worldFrame: CardFrame) -> CardView {
        removeCard(id: id)
        let card = CardView(id: id, worldFrame: worldFrame)
        card.addedOrder = cardsAdded
        cardsAdded += 1
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
        guard let card = cards[id] else {
            culls.forget(id)
            return
        }
        // While the card is still on the board, so what its gesture moved is
        // committed like any other. Settling it reprojects the card, which
        // records it in the cull ledger again: forget it after.
        card.cancelGesture()
        cards[id] = nil
        culls.forget(id)
        if carry?.owner == id { carry = nil }
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
            center: viewport.center,
            viewportCenter: viewportCenter
        )
    }

    func viewToWorld(_ p: CGPoint) -> CGPoint {
        BoardTransform.viewToWorld(
            p,
            zoom: viewport.zoom,
            center: viewport.center,
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
            BoardFly(from: viewport, to: target),
            onFrame: { [weak self] frame in self?.show(frame) },
            onLanding: { [weak self] in
                guard let self else { return }
                self.onLayoutChanged?(self.viewport)
            }
        )
    }

    /// Flies to `cardID`'s center at zoom 1.
    func fly(to cardID: CardID) {
        guard let card = cards[cardID] else { return }
        flyTo(BoardFly.destination(showing: card.worldFrame.rect))
    }

    /// Centers on the bounding box of every card with a 10 % margin a side.
    /// Does nothing on an empty board.
    func fitToCards() {
        let rects = cards.values.map(\.worldFrame.rect)
        guard let fit = BoardWayfinding.fit(
            cards: rects,
            viewportSize: bounds.size,
            margin: 0.1,
            minZoom: Viewport.minZoom,
            maxZoom: Viewport.maxZoom
        ) else { return }
        setViewport(Viewport(zoom: fit.zoom, cx: fit.center.x, cy: fit.center.y), commit: true)
    }

    /// Multiplies the zoom by `factor`, keeping the world point under
    /// `anchorViewPoint` (the board's center by default) where it is on screen.
    func zoom(by factor: CGFloat, anchorViewPoint: CGPoint? = nil) {
        flight.cancel()
        let zoomed = BoardTransform.zoomed(
            viewport,
            by: factor,
            about: anchorViewPoint ?? viewportCenter,
            viewportCenter: viewportCenter,
            limits: Viewport.minZoom...Viewport.maxZoom
        )
        if zoomed != viewport { show(zoomed) }
        onLayoutChanged?(viewport)
    }

    // MARK: - Selection and stacking

    /// The one selected card: it wears the ring and its body takes the wheel.
    /// Only a board that is on screen can hold a selection, so a card set
    /// up on a background board never arrives already selected.
    private(set) var selectedID: CardID?

    /// Selects `id`, or clears the selection with nil. Selecting never
    /// reorders cards — `raise` does that.
    func select(_ id: CardID?) {
        let id = CardSelection.resolve(id, onScreen: window != nil, isOnBoard: { cards[$0] != nil })
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

    /// Orders subviews back to front by `ZOrder.Place`, which leaves no two
    /// cards tied: `sortSubviews` does not promise to keep ties in order. Sorted
    /// in place: taking a card out of the hierarchy to re-add it resigns the
    /// window's first responder inside it, severs a press in flight, and
    /// reloads a web view.
    private func restack() {
        cardLayer.sortSubviews({ a, b, _ in
            MainActor.assumeIsolated {
                guard let a = (a as? CardView)?.stackPlace, let b = (b as? CardView)?.stackPlace else {
                    return .orderedSame
                }
                return a < b ? .orderedAscending : b < a ? .orderedDescending : .orderedSame
            }
        }, context: nil)
    }

    // MARK: - Internals

    private let cardLayer = CardLayerView()
    private let edgeLayer = EdgeLayerView()
    /// A terminal card's attached docs, held while that card is being moved by
    /// its header. Only a header move carries them: a resize from the left or
    /// top also shifts the terminal's origin, and must leave its docs where
    /// they are.
    private var carry: CardCarry<CardID>?
    private let cursors = HoverCursorRouter()
    private let flight = ViewportFlight()
    private var culls = CullLedger<CardID>()
    private var pointerTracking: NSTrackingArea?

    private var viewportCenter: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func clampZoom(_ vp: Viewport) -> Viewport {
        var vp = vp
        vp.zoom = BoardTransform.clampedZoom(vp.zoom, limits: Viewport.minZoom...Viewport.maxZoom)
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

    private func beginCarry(for card: CardView) {
        carry = nil
        guard case .term = card.id else { return }
        let attached = cards.filter { $0.value.ownerTermID == card.id && $0.value.attached }
        carry = CardCarry(
            owner: card.id,
            ownerOrigin: card.worldFrame.rect.origin,
            satellites: attached.mapValues(\.worldFrame.rect.origin)
        )
    }

    private func carrySatellites(of card: CardView) {
        guard let carry else { return }
        for (id, origin) in carry.origins(moving: card.id, to: card.worldFrame.rect.origin) {
            guard let satellite = cards[id] else { continue }
            satellite.worldFrame.x = origin.x
            satellite.worldFrame.y = origin.y
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
        // A card's callbacks can outlive its place on the board, and a card
        // that is gone must not be culled back into the ledger.
        guard cards[card.id] === card else { return }
        project(card)
        recomputeEdges()
        onCardsChanged?()
    }

    /// Places a card on screen, at the frame and the scale its chrome is laid
    /// out for. The card keeps its body at world size whatever the zoom: only a
    /// resize changes that, which is the one time a terminal re-measures its
    /// grid.
    private func project(_ card: CardView) {
        card.project(
            to: screenFrame(of: card.worldFrame.rect),
            scale: CardScale(zoom: viewport.zoom, backing: window?.backingScaleFactor ?? 2)
        )
        cull(card)
    }

    /// A world rect's place on screen, with its origin and its size each moved
    /// to the nearest whole device pixel. An edge between pixels is drawn
    /// across two, which softens the border and everything laid out from it —
    /// plainly so on a 1× display. The size is rounded by itself, not as the
    /// gap between two rounded edges, so a pan never changes it: a card whose
    /// size flickered by a pixel would lay its chrome out again on every frame.
    private func screenFrame(of world: CGRect) -> CGRect {
        cardLayer.backingAlignedRect(
            worldToView(world),
            options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
        )
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
            center: viewport.center,
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

    /// A card's body is drawn at its world size and scaled, so its layers are
    /// rasterised at `CardRaster`'s density for the zoom rather than stretched.
    /// Re-applied only when the zoom changes, not on a pan.
    private var lastContentScaleZoom: CGFloat = 0
    private var contentScale: CGFloat {
        CardRaster.layerScale(backing: window?.backingScaleFactor ?? 2, zoom: viewport.zoom)
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

    /// The wheel moves the board only where the wheel router says so, through
    /// `pan(by:)` and `zoom(by:)`. A wheel that climbs the responder chain to
    /// here was the selected card's and went unused, and must not pan the
    /// board from under that card.
    override func scrollWheel(with event: NSEvent) {}

    /// Pans by a wheel's travel in screen points.
    func pan(by travel: CGVector) {
        flight.cancel()
        show(BoardTransform.panned(viewport, by: travel))
        onLayoutChanged?(viewport)
    }

    /// A pinch zooms about the pointer.
    override func magnify(with event: NSEvent) {
        zoom(
            by: BoardWheel.zoomFactor(magnification: event.magnification),
            anchorViewPoint: convert(event.locationInWindow, from: nil)
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
        cursors.pointerLeft()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cursors.attach(to: window)
        // Only the selected card's scroll thumb can show, so only it is told
        // whether the pointer is over its thumb: at every move.
        cursors.onMove = { [weak self] hit in
            guard let self, let selectedID, let card = cards[selectedID] else { return }
            card.pointerIsOverScrollThumb(hit === card.scrollThumb)
        }
        if window == nil {
            select(nil)
            flight.cancel()
            // No release reaches a view that has left its window.
            cards.values.forEach { $0.cancelGesture() }
        }
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
