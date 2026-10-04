import AppKit
import QuartzCore
import TarmacKit

/// A card on the board: a 30-high header over a terminal or a doc, placed by
/// a world frame. The board gives it an on-screen `frame` and the scale it is
/// shown at. The chrome — border, header, shadow — is laid out at that size, so
/// it is drawn sharp at every zoom. The body is not: it keeps its world size
/// inside a container the zoom scales, so the content never reflows under zoom.
/// The header drags the card and eight invisible handles resize it.
@MainActor
final class CardView: NSView {
    let id: CardID
    let header: CardHeaderView
    private(set) var docBody: (any DocCardBody)?
    private(set) var termBody: TerminalBodyView?

    /// Where the card is in the world. The board derives the on-screen `frame`
    /// from it, and a move or resize gesture changes it.
    var worldFrame: CardFrame

    /// The card's turn among the cards added to its board.
    var addedOrder = 0

    var stackPlace: ZOrder.Place {
        ZOrder.Place(z: worldFrame.z, added: addedOrder)
    }

    /// A header press, which may become a move, went down on this card.
    var onMoveBegan: ((CardView) -> Void)?
    /// The gesture changed `worldFrame`; the board reprojects the card.
    var onFrameChanging: ((CardView) -> Void)?
    /// The pointer was released, with what the gesture amounted to.
    var onGestureEnded: ((CardView, CardGesture.Outcome) -> Void)?
    /// The header `✕` of a doc card was clicked.
    var onClose: ((CardView) -> Void)?
    /// The header `↻` of a doc card was clicked.
    var onRefresh: ((CardView) -> Void)?

    // MARK: - Provenance

    /// The terminal card that opened this doc, or nil for a terminal card and
    /// for a doc with no owner. The board draws an edge to it and, while the
    /// doc is `attached`, carries the doc along when that terminal is moved.
    var ownerTermID: CardID?

    /// Whether the doc follows its owner terminal. Moving the doc by hand
    /// detaches it; persisted inverted, as the tile's `loose` flag.
    var attached = true

    private let clip = FlippedColumnView()
    /// Scales the body: its frame is the body's place on screen, its bounds
    /// the body's world size.
    private let bodyHost = FlippedColumnView()
    private let body: NSView
    /// Chrome over the body's right edge, laid out on screen like the header.
    let scrollThumb = ScrollThumbView()
    var scrollMetrics: ScrollMetrics?
    var scrollVisibility = ScrollIndicator.Visibility()
    var scrollFade: DispatchWorkItem?
    /// The drag of the thumb in flight, the watch for its release, and the
    /// body the thumb was last laid out against.
    var scrollDrag: ScrollDrag?
    var scrollRelease: Any?
    var scrollTrackBody = CGRect.zero
    /// Scrolls a terminal card's content; a doc card's body scrolls itself.
    var onScrollTo: ((Double) -> Void)?
    private let grip = CardResizeGrip()
    private lazy var gestures = CardGestureTracker(card: self)

    private(set) var selected = false
    private(set) var fresh = false
    private var lifted = false
    /// The board's prime terminal: a tinted header and a deeper shadow.
    private(set) var prime = false
    /// A live terminal stepping back beside the prime one.
    private(set) var quiet = false
    /// A terminal whose shell exited with an error or a signal and is held open
    /// so the failure stays visible. A dead card is left out of the persisted
    /// layout.
    private(set) var dead = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(id: CardID, worldFrame: CardFrame) {
        self.id = id
        self.worldFrame = worldFrame
        switch id {
        case .term:
            header = CardHeaderView(kind: .terminal)
            let term = TerminalBodyView()
            termBody = term
            body = term
        case .doc(let path):
            header = CardHeaderView(kind: .doc(DocKind(path: path)))
            let doc = DocCardBodies.make(path: path)
            docBody = doc
            body = doc
        }
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: worldFrame.w, height: worldFrame.h)))
        wantsLayer = true
        layer?.backgroundColor = Theme.termBg.cgColor
        layer?.borderColor = Theme.line.cgColor
        applyShadow()

        // The body's container can fall short of the room under the header;
        // what shows there is the body's own colour.
        clip.wantsLayer = true
        clip.layer?.backgroundColor = (docBody == nil ? Theme.termBg : Theme.bg1).cgColor
        clip.layer?.masksToBounds = true
        addSubview(clip)
        clip.addSubview(header)
        clip.addSubview(bodyHost)
        clip.addSubview(scrollThumb)
        bodyHost.addSubview(body)

        addSubview(grip)
        grip.onPress = { [weak self] event in self?.gestures.gripPressed(event) }
        grip.onDrag = { [weak self] event in self?.gestures.dragged(event) }
        grip.onRelease = { [weak self] in self?.gestures.end() }

        header.onMouseDown = { [weak self] event in self?.gestures.headerPressed(event) }
        header.onMouseDragged = { [weak self] event in self?.gestures.dragged(event) }
        header.onMouseUp = { [weak self] _ in self?.gestures.end() }

        header.closeButton?.onClick = { [weak self] in
            guard let self else { return }
            self.onClose?(self)
        }
        header.refreshButton?.onClick = { [weak self] in
            guard let self else { return }
            self.onRefresh?(self)
        }
        wireHTMLBody()
        docBody?.onScrollChanged = { [weak self] metrics in self?.scrollChanged(metrics) }
        docBody?.onScrollCoverChanged = { [weak self] in self?.needsLayout = true }
        scrollThumb.liesOverADoc = docBody != nil
        scrollThumb.onPress = { [weak self] event in self?.thumbPressed(event) }
        scrollThumb.onDrag = { [weak self] event in self?.thumbDragged(event) }
        scrollThumb.onWheel = { [weak self] event in self?.bodyView(at: event.locationInWindow)?.scrollWheel(with: event) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    func attachTerminal(_ terminal: NSView) {
        termBody?.attach(terminal)
        contentAdded()
    }

    /// The subtree grew at an unchanged scale, which the walk would skip.
    func contentAdded() {
        applyContentScale(appliedBodyScale, force: true)
    }

    /// The scales last walked onto the layer tree. 0 until the first walk, so
    /// that one always runs: a new layer starts at scale 1, not the backing scale.
    private var appliedBodyScale: CGFloat = 0
    private var appliedChromeScale: CGFloat = 0

    /// Sets `contentsScale` on every layer in the card. The body is drawn at
    /// its world size and scaled, so its layers take `bodyScale` — the density
    /// they are shown at — instead of being stretched; the chrome is laid out
    /// at its size on screen and takes the display's own. A web view's tiles
    /// are drawn in another process and ignore this; `applyBoardZoom`
    /// reaches them. Unchanged scales are skipped unless `force` says the
    /// subtree itself changed.
    func applyContentScale(_ bodyScale: CGFloat, force: Bool = false) {
        let chromeScale = scale.backing
        guard force || bodyScale != appliedBodyScale || chromeScale != appliedChromeScale else { return }
        appliedBodyScale = bodyScale
        appliedChromeScale = chromeScale
        func walk(_ layer: CALayer, _ contentsScale: CGFloat) {
            layer.contentsScale = contentsScale
            layer.sublayers?.forEach { walk($0, contentsScale) }
        }
        func walkViews(_ view: NSView, _ inherited: CGFloat) {
            let contentsScale = view === bodyHost ? bodyScale : inherited
            if let layer = view.layer { walk(layer, contentsScale) }
            view.subviews.forEach { walkViews($0, contentsScale) }
        }
        walkViews(self, chromeScale)
        // The terminal draws only when asked; its raster must not wait for the
        // next output to pick up the new scale.
        termBody?.terminal?.needsDisplay = true
    }

    func setTermLabel(_ label: String) {
        // A dead card keeps the label it died with.
        guard !dead else { return }
        header.setLabel(label)
    }

    func apply(doc: RestoreDoc) {
        header.apply(doc: doc)
    }

    /// The board's zoom, for a doc body, which sizes its web view by it.
    func applyBoardZoom(_ zoom: CGFloat) {
        docBody?.setBoardZoom(zoom)
    }

    // MARK: - Selection

    /// Shows or drops the selection ring. The board owns which card is
    /// selected; this is only how the card looks.
    func setSelected(_ on: Bool) {
        guard on != selected else { return }
        selected = on
        if !lifted { layer?.borderColor = currentBorderColor.cgColor }
        if !on { hideScrollThumb() }
    }

    /// The resting border: muted for a dead card, teal for the selected one,
    /// else the plain line. Prime and fresh never change it, and the lift
    /// border overrides it while a gesture holds the card.
    private var currentBorderColor: NSColor {
        if borrowed { return Theme.amber }
        switch CardChrome.borderRole(chromeState) {
        case .muted: return Theme.line.withAlphaComponent(0.6)
        case .focus: return Theme.focusBorder
        case .plain: return Theme.line
        }
    }

    private var chromeState: CardChrome.State {
        CardChrome.State(dead: dead, fresh: fresh, prime: prime, selected: selected)
    }

    // MARK: - Fresh

    /// A doc an agent just opened wears a 3-wide teal ring outside its border
    /// and `✚ now` in its header. Only ESC and a completed drag of the card take
    /// it off; selecting the card does not.
    private let ringLayer = CALayer()
    private static let ringWidth: CGFloat = 3

    func setFresh(_ on: Bool) {
        guard on != fresh else { return }
        fresh = on
        header.setFreshMeta(on)
        applyRing()
    }

    /// The borrowed HTML card holds the keyboard: an amber border and ring,
    /// over whatever border and ring it wore.
    private(set) var borrowed = false

    func setBorrowed(_ on: Bool) {
        htmlBody?.setBorrowed(on)
        guard on != borrowed else { return }
        borrowed = on
        if !lifted { layer?.borderColor = currentBorderColor.cgColor }
        applyRing()
    }

    private func applyRing() {
        guard let layer else { return }
        guard let ring = CardRing.of(fresh: fresh, borrowed: borrowed) else {
            ringLayer.removeFromSuperlayer()
            return
        }
        ringLayer.backgroundColor = (ring == .borrowed ? Theme.amber.withAlphaComponent(0.16) : Theme.agentDim).cgColor
        if ringLayer.superlayer == nil { layer.insertSublayer(ringLayer, at: 0) }
        layoutRing()
    }

    private func layoutRing() {
        guard ringLayer.superlayer != nil else { return }
        let w = scale.length(Self.ringWidth)
        // The ring is a bare layer, which would ease to its new frame a quarter
        // of a second behind the card it surrounds.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = bounds.insetBy(dx: -w, dy: -w)
        ringLayer.cornerRadius = scale.length(CardBox.cornerRadius + Self.ringWidth)
        CATransaction.commit()
    }

    // MARK: - Prime, quiet, dead

    func setPrime(_ on: Bool) {
        guard !dead, on != prime else { return }
        prime = on
        header.setPrime(on)
        applyShadow()
    }

    /// Whether the card steps back is the board's call (`CardDim.isQuiet`).
    func setQuiet(_ on: Bool) {
        guard on != quiet else { return }
        quiet = on
        applyDim()
    }

    /// Holds an exited terminal's card open: dimmed, border muted, prime and
    /// bell dropped, the label left as it was. The exit code is the toast's to
    /// show, not the card's.
    func setExited() {
        guard !dead else { return }
        setBell(false)
        setLive(false)
        setPrime(false)
        dead = true
        layer?.borderColor = currentBorderColor.cgColor
        applyDim()
    }

    private func applyDim() {
        alphaValue = CardDim.opacity(dead: dead, quiet: quiet)
    }

    // MARK: - Owner chip

    /// Shows `← <name>` in the header, or hides the chip with nil.
    func setOwnerChip(_ termName: String?) {
        header.setOwnerChip(termName)
    }

    // MARK: - Signals

    private(set) var bellActive = false
    private(set) var liveActive = false

    /// What the minimap and the offscreen hints show for this card. A lit bell
    /// outranks live.
    var signal: CardSignal {
        if bellActive { return .bell }
        if liveActive { return .live }
        return .none
    }

    /// A lit bell shows as an amber glyph and dot in the header.
    func setBell(_ on: Bool) {
        guard !dead, on != bellActive else { return }
        bellActive = on
        header.setBell(on)
    }

    func setLive(_ on: Bool) {
        guard !dead, on != liveActive else { return }
        liveActive = on
    }

    // MARK: - Layout

    /// The board's zoom and the display's density, as the card was last put
    /// on screen.
    private(set) var scale = CardScale(zoom: 1, backing: 2)

    /// The world size the body was last laid out at. Far zoomed out, a resize
    /// can change it without moving the card's frame by a device pixel.
    private var laidOutWorldSize: CGSize?

    /// The scale the card was last projected at. A culled card is not laid
    /// out for it until it is shown.
    private var projectedScale = CardScale(zoom: 1, backing: 2)

    /// Puts the card on screen at `frame`, its chrome laid out for `scale`. A
    /// culled card takes only its place, which the edges ending on it read,
    /// and its body's size, which a terminal measures its grid from: on a
    /// board of many cards, laying out chrome nobody sees is most of what a
    /// zoom step costs.
    func project(to frame: CGRect, scale: CardScale) {
        let resized = worldFrame.rect.size != laidOutWorldSize
        let reshaped = frame.size != self.frame.size || scale != self.scale
        self.frame = frame
        projectedScale = scale
        if isHidden {
            if resized { needsLayout = true }
            return
        }
        if resized || reshaped { needsLayout = true }
        applyProjectedScale()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
        applyProjectedScale()
    }

    private func applyProjectedScale() {
        guard projectedScale != scale else { return }
        scale = projectedScale
        header.apply(scale)
        applyShadow()
    }

    override func layout() {
        super.layout()
        // AppKit asks for a layout whenever the frame's size changes, which
        // for a culled card is every zoom step.
        if isHidden, worldFrame.rect.size == laidOutWorldSize { return }
        let box = CardBox.screen(cardSize: bounds.size, worldSize: worldFrame.rect.size, scale: scale)
        layer?.cornerRadius = box.cornerRadius
        layer?.borderWidth = box.border
        clip.frame = box.content
        // The content sits inside the border, so its corners follow the
        // border's inner edge.
        clip.layer?.cornerRadius = max(0, box.cornerRadius - box.border)
        header.frame = box.header
        bodyHost.frame = box.body
        // A new frame size drags the bounds along with it, so they are put back
        // to the world size. The body is sized from the world frame and not
        // from those bounds, which read back a few ulps off it: laid out from
        // them, every zoom step would hand the terminal a new size.
        bodyHost.setBoundsSize(box.bodySize)
        body.frame = NSRect(origin: .zero, size: box.bodySize)
        layoutScrollThumb(body: box.shownBody)
        laidOutWorldSize = worldFrame.rect.size
        layoutRing()
    }

    // MARK: - Resize handles

    /// Screen points per world unit.
    var screenScale: CGFloat { scale.zoom }

    /// The resize handle under `point`, given in the superview's coordinates —
    /// screen points, where the hit zones keep a fixed size at every zoom.
    func resizeHandle(at point: NSPoint) -> CardResize.Handle? {
        CardHandles.handle(
            at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
            cardSize: frame.size,
            hasClose: header.closeButton != nil
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let thumb = scrollThumb.isHidden ? nil : superview.map { clip.convert(scrollThumb.frame, to: $0) }
        switch CardHit.at(point, thumb: thumb, grabbable: scrollThumbCanBeGrabbed, handle: resizeHandle(at: point)) {
        case .thumb: return scrollThumb
        case .handle: return grip
        case .content: return hit
        }
    }

    /// Ends a move, a resize or a drag of the scroll thumb in flight as its
    /// release would. For when the card goes away under the pointer and the
    /// release will never reach it.
    func cancelGesture() {
        gestures.end()
        endScrollDrag()
    }

    /// The view of the body under a point of the window, whatever lies over it.
    func bodyView(at windowPoint: NSPoint) -> NSView? {
        bodyHost.hitTest(clip.convert(windowPoint, from: nil))
    }

    /// Whether `view` is the card's body or inside it — not the header, and not
    /// a resize handle lying over the body's edge.
    func bodyContains(_ view: NSView) -> Bool {
        view.isDescendant(of: bodyHost)
    }

    // MARK: - Shadow and lift

    /// Every card casts a shadow: deeper for the prime terminal, and for a
    /// card held by a gesture. Its metrics are world units, so they take the
    /// zoom like the rest of the chrome.
    private func applyShadow() {
        let (alpha, drop, blur): (CGFloat, CGFloat, CGFloat) =
            lifted ? (0.6, 18, 22) : prime ? (0.6, 22, 25) : (0.5, 16, 19)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowOffset = NSSize(width: 0, height: -scale.length(drop))
        shadow.shadowBlurRadius = scale.length(blur)
        self.shadow = shadow
    }

    /// Picked-up styling while a move or resize holds the card; on release the
    /// border eases back to its resting colour.
    func setLifted(_ on: Bool) {
        guard on != lifted, let layer else { return }
        lifted = on
        applyShadow()
        if on {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = Theme.liftBorder.cgColor
            CATransaction.commit()
        } else {
            let ease = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            let border = CABasicAnimation(keyPath: "borderColor")
            border.fromValue = Theme.liftBorder.cgColor
            border.toValue = currentBorderColor.cgColor
            border.duration = 0.15
            border.timingFunction = ease
            layer.borderColor = currentBorderColor.cgColor
            layer.add(border, forKey: "liftBorderOff")
        }
    }
}

/// What a card shows on the minimap and in the offscreen hints.
enum CardSignal: Equatable {
    case none
    case live
    case bell
}

extension CardView: @MainActor ClearableFreshDoc {
    var isFreshDoc: Bool {
        if case .doc = id { return fresh }
        return false
    }

    func clearFresh() {
        setFresh(false)
    }
}
