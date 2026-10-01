import AppKit
import QuartzCore
import TarmacKit

/// A card on the board: a 30-high header over a terminal or a doc, placed by
/// a world frame. The board gives it an on-screen `frame` that carries the
/// zoom while its `bounds` stay in world units, so the content never reflows
/// under zoom. The header drags it and eight invisible handles resize it.
@MainActor
final class CardView: NSView {
    let id: CardID
    let header: CardHeaderView
    private(set) var docView: DocWebView?
    private(set) var termBody: TerminalBodyView?

    /// Where the card is in the world. The board derives the on-screen `frame`
    /// from it, and a move or resize gesture changes it.
    var worldFrame: CardFrame

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
    private let body: NSView
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
            let doc = DocWebView()
            doc.wantsLayer = true
            doc.layer?.backgroundColor = Theme.bg1.cgColor
            docView = doc
            body = doc
        }
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: worldFrame.w, height: worldFrame.h)))
        wantsLayer = true
        layer?.backgroundColor = Theme.termBg.cgColor
        layer?.cornerRadius = CardBox.cornerRadius
        layer?.borderWidth = CardBox.borderWidth
        layer?.borderColor = Theme.line.cgColor
        applyRestingShadow()

        // The content sits inside the border, so its corners follow the
        // border's inner edge.
        clip.wantsLayer = true
        clip.layer?.cornerRadius = CardBox.cornerRadius - CardBox.borderWidth
        clip.layer?.masksToBounds = true
        addSubview(clip)
        clip.addSubview(header)
        clip.addSubview(body)

        addSubview(grip)
        grip.onPress = { [weak self] event in self?.gestures.gripPressed(event) }
        grip.onDrag = { [weak self] event in self?.gestures.dragged(event) }
        grip.onRelease = { [weak self] in self?.gestures.released() }

        header.onMouseDown = { [weak self] event in self?.gestures.headerPressed(event) }
        header.onMouseDragged = { [weak self] event in self?.gestures.dragged(event) }
        header.onMouseUp = { [weak self] _ in self?.gestures.released() }

        header.closeButton?.onClick = { [weak self] in
            guard let self else { return }
            self.onClose?(self)
        }
        header.refreshButton?.onClick = { [weak self] in
            guard let self else { return }
            self.onRefresh?(self)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    func attachTerminal(_ terminal: NSView) {
        termBody?.attach(terminal)
        // The subtree grew at an unchanged scale, which the walk would skip.
        applyContentScale(appliedContentScale, force: true)
    }

    /// The scale last walked onto the layer tree. 0 until the first walk, so
    /// that one always runs: a new layer starts at scale 1, not the backing scale.
    private var appliedContentScale: CGFloat = 0

    /// Sets `contentsScale` on every layer in the card, so the card's own
    /// layers — the terminal and the chrome — are rasterised at the density
    /// they are shown at instead of being stretched. A web view's tiles are
    /// drawn in another process and ignore this; `applyDocZoomScale` reaches
    /// them. An unchanged scale is skipped unless `force` says the subtree
    /// itself changed.
    func applyContentScale(_ scale: CGFloat, force: Bool = false) {
        guard force || scale != appliedContentScale else { return }
        appliedContentScale = scale
        func walk(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(walk)
        }
        func walkViews(_ view: NSView) {
            if let layer = view.layer { walk(layer) }
            view.subviews.forEach(walkViews)
        }
        walkViews(self)
        // The terminal draws only when asked; its raster must not wait for the
        // next output to pick up the new scale.
        termBody?.terminal?.needsDisplay = true
    }

    func setTermLabel(_ label: String) {
        header.setLabel(label)
    }

    func apply(doc: RestoreDoc) {
        header.apply(doc: doc)
    }

    func renderDoc(markdown: String) {
        docView?.render(markdown: markdown)
    }

    func suspendDoc() { docView?.suspend() }
    func resumeDoc() { docView?.resume() }

    func applyDocZoomScale(_ effectiveScale: CGFloat) {
        docView?.applyZoomScale(effectiveScale)
    }

    // MARK: - Selection

    /// Shows or drops the selection ring. The board owns which card is
    /// selected; this is only how the card looks.
    func setSelected(_ on: Bool) {
        guard on != selected else { return }
        selected = on
        if !lifted { layer?.borderColor = currentBorderColor.cgColor }
    }

    /// The resting border: muted for a dead card, teal for the selected one,
    /// else the plain line. Prime and fresh never change it, and the lift
    /// border overrides it while a gesture holds the card.
    private var currentBorderColor: NSColor {
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
        guard on != fresh, let layer else { return }
        fresh = on
        if on {
            ringLayer.backgroundColor = Theme.agentDim.cgColor
            ringLayer.cornerRadius = CardBox.cornerRadius + Self.ringWidth
            layer.insertSublayer(ringLayer, at: 0)
        } else {
            ringLayer.removeFromSuperlayer()
        }
        header.setFreshMeta(on)
        layoutRing()
    }

    private func layoutRing() {
        guard fresh else { return }
        let w = Self.ringWidth
        ringLayer.frame = contentBox.insetBy(dx: -w, dy: -w)
    }

    // MARK: - Prime, quiet, dead

    func setPrime(_ on: Bool) {
        guard !dead, on != prime else { return }
        prime = on
        header.setPrime(on)
        if !lifted { applyRestingShadow() }
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
    func setExited(_ code: Int?) {
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

    /// The box the content is laid out in. The board zooms a card by giving it
    /// a frame that differs from its bounds, and `bounds` then reads back
    /// through that scale a few ulps off the world size; laid out from it,
    /// every zoom step would hand the terminal a new size.
    private var contentBox: NSRect {
        NSRect(x: 0, y: 0, width: worldFrame.w, height: worldFrame.h)
    }

    override func layout() {
        super.layout()
        let size = contentBox.size
        clip.frame = CardBox.content(of: size)
        header.frame = CardBox.header(of: size)
        body.frame = CardBox.body(of: size)
        layoutRing()
    }

    // MARK: - Resize handles

    /// Screen points per world unit: the frame carries the board zoom and the
    /// world frame does not.
    var screenScale: CGFloat {
        worldFrame.w > 0 ? frame.width / worldFrame.w : 1
    }

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
        return resizeHandle(at: point) == nil ? hit : grip
    }

    /// Whether `view` is the card's body or inside it — not the header, and not
    /// a resize handle lying over the body's edge.
    func bodyContains(_ view: NSView) -> Bool {
        view.isDescendant(of: body)
    }

    // MARK: - Shadow and lift

    /// Every card casts a shadow at rest, a prime terminal a deeper one. In
    /// the card's own units, so it scales with the zoom like the rest of it.
    private func applyRestingShadow() {
        let shadow = NSShadow()
        if prime {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = NSSize(width: 0, height: -22)
            shadow.shadowBlurRadius = 25
        } else {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowOffset = NSSize(width: 0, height: -16)
            shadow.shadowBlurRadius = 19
        }
        self.shadow = shadow
    }

    /// Picked-up styling while a move or resize holds the card; on release the
    /// border eases back to its resting colour.
    func setLifted(_ on: Bool) {
        guard on != lifted, let layer else { return }
        lifted = on
        if on {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = Theme.liftBorder.cgColor
            CATransaction.commit()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = NSSize(width: 0, height: -18)
            shadow.shadowBlurRadius = 22
            self.shadow = shadow
        } else {
            applyRestingShadow()
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
