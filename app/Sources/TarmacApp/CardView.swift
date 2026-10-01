import AppKit
import QuartzCore
import TarmacKit

/// A card on the board: a 30-high header over a terminal or a doc, placed by
/// a world frame. The board gives it an on-screen `frame` that carries the
/// zoom while its `bounds` stay in world units, so the content never reflows
/// under zoom. The header drags it and eight invisible handles resize it.
@MainActor
final class CardView: NSView {
    static let headerHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 10
    let id: CardID
    let header: TileHeaderView
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
    /// The header ✕ (doc cards only) was clicked — the board routes it to the
    /// controller, which closes the doc card.
    var onClose: ((CardView) -> Void)?

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
    /// Prime = the focused terminal card (crib §4): border `#5a626a`, header
    /// `#3a4046` + text label, deeper shadow `0 22px 50px rgba(0,0,0,0.6)`.
    private(set) var prime = false
    /// Quiet = a non-prime card while a terminal is prime (crib §4): opacity 0.8.
    private(set) var quiet = false
    /// Dead = a terminal card whose shell exited with an error/signal and is held
    /// open (2606.0001): the card stays on the board dimmed, labelled `exit N` /
    /// `killed`, read-only, and never reads as prime/quiet. Set via `setExited`.
    /// (A clean exit removes the card outright, so it never becomes `dead`.) This
    /// flag is also the "exited" signal `persistLayout` uses to exclude the card.
    private(set) var dead = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(id: CardID, worldFrame: CardFrame) {
        self.id = id
        self.worldFrame = worldFrame
        switch id {
        case .term:
            header = TileHeaderView(kindGlyph: "›_", showsRepoDot: false, closeButton: nil)
            let term = TerminalBodyView()
            termBody = term
            body = term
        case .doc:
            header = TileHeaderView(kindGlyph: "¶", showsRepoDot: true, closeButton: CloseButton())
            let doc = DocWebView()
            docView = doc
            body = doc
        }
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: worldFrame.w, height: worldFrame.h)))
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.line.cgColor
        applyRestingShadow()

        clip.wantsLayer = true
        clip.layer?.backgroundColor = Theme.bg1.cgColor
        clip.layer?.cornerRadius = Self.cornerRadius
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
        header.closeButton?.isHidden = true
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
        // An exited (held-open) card keeps its `exit N` / `killed` label.
        guard !dead else { return }
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
        header.closeButton?.isHidden = !on
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

    // MARK: - Fresh state (crib §4/§5): 3px agent-dim halo + `✚ now` meta, no border.

    /// Cyan-dim halo just outside the border (`box-shadow 0 0 0 3px agent-dim`).
    /// Sits behind the card's own (clipped) content on the non-clipped outer
    /// layer; cleared when the card is selected or its doc is marked read. `fresh`
    /// drives only this halo + the `✚ now` meta — never the border, which stays
    /// on the `CardChrome.borderRole` axis so a non-active fresh card reads plain.
    private let ringLayer = CALayer()
    private static let ringWidth: CGFloat = 3

    func setFresh(_ on: Bool) {
        guard on != fresh, let layer else { return }
        fresh = on
        if on {
            ringLayer.backgroundColor = Theme.agentDim.cgColor
            ringLayer.cornerRadius = Self.cornerRadius + Self.ringWidth
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

    // MARK: - Prime / quiet states (crib §4: terminal primacy)

    /// Prime = the keyboard-target terminal (crib §4): header `#3a4046` + `text`
    /// label and a deeper resting shadow `0 22px 50px rgba(0,0,0,0.6)`; every
    /// non-prime card is `quiet` (opacity 0.8). Prime deliberately draws NO
    /// border — the active ring belongs to focus/selection alone (`CardChrome`).
    /// Set by the controller from the focus model; exactly one live terminal is
    /// prime (the one ⌥tab / ⌘T / a click last focused).
    func setPrime(_ on: Bool) {
        guard !dead, on != prime else { return }
        prime = on
        // A prime card is never simultaneously quiet.
        if on { setQuiet(false) }
        header.setPrime(on)
        // Only the resting shadow follows prime; the border does not (prime is
        // not a border input). Skip while transiently lifted by a gesture.
        if !lifted { applyRestingShadow() }
    }

    /// Quiet = a non-prime card while a terminal holds prime focus (crib §4):
    /// opacity 0.8. Cleared when nothing is prime (every card back to full). A
    /// dead terminal card keeps its own dim and ignores quiet.
    func setQuiet(_ on: Bool) {
        guard !dead, on != quiet else { return }
        quiet = on
        alphaValue = on ? 0.8 : 1.0
    }

    // MARK: - Exited state (2606.0001: shell exited with an error/signal — held open)

    /// Marks a terminal card a read-only hold-open placeholder after its shell
    /// exited with an error or was killed by a signal: dim it, mute the border,
    /// drop any prime styling, and label the header `exit N` (or `killed` when
    /// the exit code is nil). The card stays on the board at its world frame so
    /// the failure stays visible; a clean (code 0) exit removes the card instead
    /// and never reaches here. ⌘W closes the placeholder; it is session-local
    /// either way and clears on relaunch, since this `dead` state excludes it
    /// from the persisted layout (spec 2606.0001).
    func setExited(_ code: Int?) {
        guard !dead else { return }
        // Clear any live/bell signal first (while still !dead so the guarded
        // setters apply) — an exited card must not advertise a cyan/amber signal.
        setBell(false)
        setLive(false)
        dead = true
        prime = false
        quiet = false
        header.setPrime(false)
        alphaValue = 0.55
        layer?.borderColor = currentBorderColor.cgColor
        applyRestingShadow()
        let label = code.map { "exit \($0)" } ?? "killed"
        header.setLabel(label)
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
        let box = contentBox
        clip.frame = box
        header.frame = NSRect(x: 0, y: 0, width: box.width, height: Self.headerHeight)
        body.frame = NSRect(
            x: 0,
            y: Self.headerHeight,
            width: box.width,
            height: max(0, box.height - Self.headerHeight)
        )
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
