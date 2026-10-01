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

    /// World-space placement (crib §5). Set by `BoardView` on add / drag / resize;
    /// the on-screen `frame` is derived from this by the board's world→view map.
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

    // MARK: - Gravity / provenance (crib §4, §8)

    /// The term card this doc card is a satellite of (provenance + gravity
    /// owner). nil for the term card itself and for ownerless docs. The board
    /// reads it to translate satellites on term-card moves and to draw edges.
    var ownerTermID: CardID?

    /// While attached (true) the card follows its owner term card; a USER move
    /// detaches it (loose = !attached). Persisted as the tile `loose` flag.
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
        // Force: the subtree just grew a terminal at the current scale (#6).
        applyContentScale(pendingContentScale, force: true)
    }

    /// The board scales each card as a bitmap (its `frame≠bounds` transform), so
    /// zooming in past 100% upscales the rasterized content → blur. Rendering the
    /// card's whole layer tree at `backingScale × zoom` resolution gives the
    /// upscale real pixels. The board pushes the target scale here on zoom change;
    /// we remember it so content swapped in later (e.g. a revived terminal)
    /// inherits the same sharpness. NOTE: this only sharpens IN-PROCESS layers
    /// (the terminal grid, chrome) — it no-ops on a WKWebView's out-of-process
    /// tiles, which the doc card sharpens separately via `applyDocZoomScale`.
    /// Last scale walked onto the layer tree. `0` = "never applied" sentinel, so
    /// the first real apply always runs (a fresh CALayer defaults to contentsScale
    /// 1, not the backing scale).
    private var pendingContentScale: CGFloat = 0

    /// Walks the whole view+layer subtree setting `contentsScale`. Fix #6: skip the
    /// walk when `scale` is unchanged — at zoom < 1 the board's computed content
    /// scale is constant (= backing scale), so without this every zoom step
    /// re-walked every card's subtree to set the value it already had. Pass
    /// `force: true` when the SUBTREE changed at an unchanged scale (a newly
    /// attached terminal), so the new layers still get the current scale.
    func applyContentScale(_ scale: CGFloat, force: Bool = false) {
        guard force || scale != pendingContentScale else { return }
        pendingContentScale = scale
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

    /// P5.5: suspend / resume the doc card's web view (no-op on a term card).
    /// Driven by the board switch lifecycle to free inactive boards' web content
    /// processes; the cached markdown re-renders + scroll restores on resume.
    func suspendDoc() { docView?.suspend() }
    func resumeDoc() { docView?.resume() }

    /// Routes the board's zoom-derived scale to the doc card's web view so
    /// WebKit re-rasterizes its out-of-process tiles at the on-screen pixel
    /// density (no-op on a term card). This is deliberately separate from
    /// `applyContentScale`: that layer-tree walk sharpens in-process layers
    /// (the terminal grid, chrome) but NO-OPS on WKWebView's proxy tile
    /// layers, which only obey the device-scale factor pushed here.
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

    // MARK: - Owner chip bridge

    /// `← <termname>` chip in the header right cluster while attached; nil hides
    /// it (a detached/loose card shows none). The board feeds the owner term's
    /// current label.
    func setOwnerChip(_ termName: String?) {
        header.setOwnerChip(termName)
    }

    // MARK: - Bell signal bridge (Phase 3.5 / M2 honest signals)

    /// Whether the amber bell signal is currently shown on this card.
    private(set) var bellActive = false

    /// Whether the card is "live" — an agent process is active on a terminal
    /// card. Drives the cyan accents on the minimap / offscreen hint
    /// (Phase 4 wayfinding). Display state only (no animation).
    private(set) var liveActive = false

    /// The card's current signal, for the wayfinding chrome (crib §6–7). Bell
    /// (amber) outranks live (cyan) when both are set, matching the design's
    /// "the bell is the louder signal" intent.
    var signal: CardSignal {
        if bellActive { return .bell }
        if liveActive { return .live }
        return .none
    }

    /// Amber bell signal in the header (a `●` dot + amber kind-glyph accent),
    /// shown on a seen BEL and cleared on the next keystroke, paste or click in
    /// that terminal. Display state only — no animation (stays under Reduce
    /// Motion).
    func setBell(_ on: Bool) {
        guard !dead, on != bellActive else { return }
        bellActive = on
        header.setBell(on)
    }

    /// Live (agent-active) signal: a foreground process is running on a terminal
    /// card. Feeds the minimap / offscreen-hint cyan variant.
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

    // MARK: - Card shadow: resting base (crib §4) + deeper lift (crib §5)

    /// Resting card shadow (crib §4): base `0 16px 38px rgba(0,0,0,0.5)` present
    /// on every card at rest, so the board reads as floating cards over the dot
    /// grid rather than flat panes. A prime card rests deeper (`0 22px 50px
    /// rgba(0,0,0,0.6)`); the lift deepens it further, and un-lift returns here.
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

/// A card's wayfinding signal (crib §6–7), shared by the minimap and the
/// offscreen hints. `bell` (amber) outranks `live` (cyan) when both are set.
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
