import AppKit
import QuartzCore
import TarmacKit

/// A free card on the board (crib §4) — the v4 successor to `TileView`. Same
/// chrome family (reuses `TileHeaderView` / `RecentMetaLabel` / `TerminalBodyView`
/// / `DocWebView`), but a card carries a *world frame* instead of a grid slot,
/// drags to MOVE (no slot swap, no −0.5° rotation — keeps the lift shadow), and
/// shows corner resize handles once focused (or selected via a header/handle grab).
///
/// Metrics differ from `TileView` per crib §4: header **30px**, radius **10**.
/// `.tm-bcard` is `overflow:hidden`, so the selection handles live on the
/// non-clipped outer view (`self`), above the inner rounded clip. Hosted inside
/// `BoardView`.
@MainActor
final class CardView: NSView {
    static let headerHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 10
    /// The visible handle stays 7×7, but its hit/cursor target is a larger
    /// transparent box (`handleHitSize`) centered on the corner — so resizing
    /// isn't a needle-thin 7px sliver (which shrinks further when zoomed out).
    static let handleSize: CGFloat = 7
    static let handleHitSize: CGFloat = 20
    /// Inward nudge of the corner point so the square lands on the rounded
    /// visual corner instead of floating off the sharp geometric corner.
    static let handleCornerInset: CGFloat = 3
    /// Below this card size a resize can't go (header + a sliver of body).
    static let minWidth: CGFloat = 160
    static let minHeight: CGFloat = 90

    let id: CardID
    let header: TileHeaderView
    private(set) var docView: DocWebView?
    private(set) var termBody: TerminalBodyView?
    /// The semantic-zoom locard (crib §7): a compact two-row name+status view,
    /// shown in place of the chrome below the zoom threshold. Lazily built.
    private var locard: LocardView?

    /// World-space placement (crib §5). Set by `BoardView` on add / drag / resize;
    /// the on-screen `frame` is derived from this by the board's world→view map.
    var worldFrame: CardFrame

    /// Fires the moment a MOVE or RESIZE commits (mouse-up), so the board can
    /// persist the new world frame and reflow the terminal. The board sets this.
    var onFrameCommitted: ((CardView) -> Void)?
    /// Header mouse-down requesting selection/raise before a move begins.
    var onSelectRequested: ((CardView) -> Void)?
    /// The header ✕ (doc cards only) was clicked — the board routes it to the
    /// controller, which parks the doc on the shelf.
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
    private let handles: [HandleCorner: ResizeHandleView]

    private(set) var selected = false
    private(set) var fresh = false
    private var lifted = false
    /// Prime = the focused terminal card (crib §4): border `#5a626a`, header
    /// `#3a4046` + text label, deeper shadow `0 22px 50px rgba(0,0,0,0.6)`.
    private(set) var prime = false
    /// Quiet = a non-prime card while a terminal is prime (crib §4): opacity 0.8.
    private(set) var quiet = false
    /// Focused = the pointer/scroll-active card (`AppController.focusedCardID`):
    /// scrolling over it scrolls its own content. Border-only (a soft teal edge),
    /// independent of prime — a doc can be focused (scroll target) while a terminal
    /// stays prime (keyboard target). Set via `setFocused` from the focus model.
    private(set) var focused = false
    /// Dead = a terminal card whose pty exited (Phase 5b decision 1): the card
    /// stays on the board dimmed, labelled `exit N · ↵ respawn`, and never reads
    /// as prime/quiet. Set via `setDead`.
    private(set) var dead = false
    /// Detached = a terminal card whose daemon connection dropped (P5.3): faint
    /// (alpha 0.5), distinct from dead (exit). The shell may still be alive on the
    /// daemon, awaiting reconnect+rebind — so it is REVERSIBLE: the card keeps its
    /// label + frame and is cleared (`setDetached(false)`) when the term re-binds.
    private(set) var detached = false

    // Active move/resize gesture state (window-space anchors).
    private enum Gesture {
        case move(startWindow: NSPoint, startWorldX: CGFloat, startWorldY: CGFloat)
        case resize(corner: HandleCorner, startWindow: NSPoint, startFrame: CardFrame)
    }
    private var gesture: Gesture?
    /// The kind of the gesture that most recently committed — the board reads
    /// it at `onFrameCommitted` to drive gravity (a term-card MOVE translates
    /// satellites; a doc-card MOVE detaches it). Resize never touches gravity.
    private(set) var lastCommittedGestureWasMove = false
    /// World units per view point — the board's current zoom; set before a drag
    /// so pointer deltas convert to world deltas. Defaults to 1.
    var worldPerView: CGFloat = 1

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
        var built: [HandleCorner: ResizeHandleView] = [:]
        for corner in HandleCorner.allCases { built[corner] = ResizeHandleView(corner: corner) }
        handles = built

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

        for corner in HandleCorner.allCases {
            let h = handles[corner]!
            h.isHidden = true
            h.onMouseDown = { [weak self] event in self?.beginResize(corner: corner, event: event) }
            h.onMouseDragged = { [weak self] event in self?.updateGesture(event) }
            h.onMouseUp = { [weak self] _ in self?.endGesture(commit: true) }
            addSubview(h)
        }

        header.onMouseDown = { [weak self] event in self?.beginMove(event: event) }
        header.onMouseDragged = { [weak self] event in self?.updateGesture(event) }
        header.onMouseUp = { [weak self] _ in self?.endGesture(commit: true) }

        // The doc-card ✕ (no-op on a term card, whose header has none). It rides
        // the same focused/selected visibility as the resize handles, so it stays
        // hidden until the card is the user's active target.
        header.closeButton?.onClick = { [weak self] in
            guard let self else { return }
            self.onClose?(self)
        }
        header.closeButton?.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content (mirrors TileView's surface so 2c wires it the same way)

    func attachTerminal(_ terminal: NSView) {
        termBody?.attach(terminal)
        applyContentScale(pendingContentScale)
    }

    /// The board scales each card as a bitmap (its `frame≠bounds` transform), so
    /// zooming in past 100% upscales the rasterized content → blur. Rendering the
    /// card's whole layer tree at `backingScale × zoom` resolution gives the
    /// upscale real pixels. The board pushes the target scale here on zoom change;
    /// we remember it so content swapped in later (e.g. a revived terminal)
    /// inherits the same sharpness. NOTE: this only sharpens IN-PROCESS layers
    /// (the SwiftTerm grid, chrome) — it no-ops on a WKWebView's out-of-process
    /// tiles, which the doc card sharpens separately via `applyDocZoomScale`.
    private var pendingContentScale: CGFloat = 2
    func applyContentScale(_ scale: CGFloat) {
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
    }

    func setTermLabel(_ label: String) {
        // A dead card keeps its `exit N · ↵ respawn` label.
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
    /// (the SwiftTerm grid, chrome) but NO-OPS on WKWebView's proxy tile
    /// layers, which only obey the device-scale factor pushed here.
    func applyDocZoomScale(_ effectiveScale: CGFloat) {
        docView?.applyZoomScale(effectiveScale)
    }

    // MARK: - Selection

    func setSelected(_ on: Bool) {
        // Selecting a fresh card clears the fresh ring (crib §5).
        if on && fresh { setFresh(false) }
        guard on != selected else { return }
        selected = on
        layer?.borderColor = currentBorderColor.cgColor
        updateHandleVisibility()
    }

    /// Resize handles surface whenever the card is the user's active target —
    /// `focused` (a single click) OR `selected` (an explicit header/handle grab).
    /// A plain focus now arms resizing, so the handles follow focus; keeping
    /// `selected` in the condition still lets a dead card (never focusable) be
    /// resized via a header grab.
    private func updateHandleVisibility() {
        let show = focused || selected
        for (corner, h) in handles {
            // The doc card's ✕ owns the top-right corner; suppress that one resize
            // handle so the button and handle never collide. Resize stays available
            // from the other three corners.
            h.isHidden = !show || (corner == .topRight && header.closeButton != nil)
        }
        header.closeButton?.isHidden = !show
    }

    /// The base border color for the current state, highest priority first:
    /// muted line for dead/detached, agent when selected or fresh, prime's
    /// `#5a626a` for the keyboard-prime terminal, the soft teal `focusBorder` for
    /// the scroll-focused card (incl. docs), else line. The lift state overrides
    /// this transiently. `focused` sits below `prime` on purpose: when one card is
    /// both (a click on a live terminal) the louder prime border wins, so it never
    /// double-draws; the teal edge only surfaces on a focused-but-not-prime card.
    private var currentBorderColor: NSColor {
        // A dead OR detached terminal card reads muted, below selection/prime
        // accents (detached is reversible; dead is not).
        if dead || detached { return Theme.line.withAlphaComponent(0.6) }
        if selected || fresh { return Theme.agent }
        if prime { return Theme.liftBorder }
        if focused { return Theme.focusBorder }
        return Theme.line
    }

    // MARK: - Fresh state (crib §4/§5): agent border + 3px agent-dim ring.

    /// Cyan-dim halo just outside the border (`box-shadow 0 0 0 3px agent-dim`).
    /// Sits behind the card's own (clipped) content on the non-clipped outer
    /// layer; cleared when the card is selected or its doc is marked read.
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
        layer.borderColor = currentBorderColor.cgColor
        header.setFreshMeta(on)
        layoutRing()
    }

    private func layoutRing() {
        guard fresh else { return }
        let w = Self.ringWidth
        ringLayer.frame = bounds.insetBy(dx: -w, dy: -w)
    }

    // MARK: - Prime / quiet states (crib §4: terminal primacy)

    /// Prime = the focused terminal card (crib §4): border `#5a626a`, header
    /// `#3a4046` + `text` label, deeper resting shadow `0 22px 50px
    /// rgba(0,0,0,0.6)`. A non-prime card is `quiet` (opacity 0.8). Set by the
    /// controller from the focus model; exactly one live terminal is prime
    /// (Phase 5b: the one ⌥tab / ⌘T / a click last focused).
    func setPrime(_ on: Bool) {
        guard !dead, on != prime else { return }
        prime = on
        // A prime card is never simultaneously quiet.
        if on { setQuiet(false) }
        header.setPrime(on)
        // Border + shadow follow the new state when not transiently lifted.
        if !lifted {
            layer?.borderColor = currentBorderColor.cgColor
            applyRestingShadow()
        }
    }

    /// Quiet = a non-prime card while a terminal holds prime focus (crib §4):
    /// opacity 0.8. Cleared when nothing is prime (every card back to full). A
    /// dead terminal card keeps its own dim and ignores quiet.
    func setQuiet(_ on: Bool) {
        guard !dead, on != quiet else { return }
        quiet = on
        alphaValue = on ? 0.8 : 1.0
    }

    /// Focused = the scroll-active card (`AppController.focusedCardID`): a soft teal
    /// border only — no header / shadow / alpha change — so it composes with `quiet`
    /// (a focused doc beside a prime terminal is dimmed to 0.8 AND shows the teal
    /// edge) and stays subordinate to `prime`. A dead card is never a focus target.
    func setFocused(_ on: Bool) {
        guard !dead, on != focused else { return }
        focused = on
        if !lifted { layer?.borderColor = currentBorderColor.cgColor }
        updateHandleVisibility()
    }

    // MARK: - Dead state (Phase 5b decision 1: terminal exited, no auto-respawn)

    /// Marks a terminal card dead: dim it, mute the border, drop any prime
    /// styling, and label the header `exit N · ↵ respawn` (or `killed · ↵
    /// respawn` when the exit code is nil). The card stays on the board at its
    /// world frame; the user revives it explicitly (respawn UI is post-5b).
    func setDead(_ code: Int?) {
        guard !dead else { return }
        // Clear any live/bell signal first (while still !dead so the guarded
        // setters apply) — a dead card must not advertise a cyan/amber signal.
        setBell(false)
        setLive(false)
        dead = true
        prime = false
        quiet = false
        header.setPrime(false)
        alphaValue = 0.55
        layer?.borderColor = currentBorderColor.cgColor
        applyRestingShadow()
        let label = code.map { "exit \($0) · ↵ respawn" } ?? "killed · ↵ respawn"
        header.setLabel(label)
    }

    /// P5.3: marks a terminal card detached (the daemon connection dropped) — dim
    /// it (alpha 0.5) and mute its border, WITHOUT relabelling or going dead: the
    /// shell may still be alive on the daemon and the card re-binds on reconnect.
    /// A dead card ignores detach (its exit is terminal). Clearing it (`false`)
    /// restores the resting alpha (quiet-aware) + the state border.
    func setDetached(_ on: Bool) {
        guard !dead, on != detached else { return }
        detached = on
        alphaValue = on ? 0.5 : (quiet ? 0.8 : 1.0)
        layer?.borderColor = currentBorderColor.cgColor
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
    /// card. Drives the cyan accents on the locard / minimap / offscreen hint
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
    /// shown on a seen BEL and cleared on the next keystroke / focus. Display
    /// state only — no animation (stays under Reduce Motion).
    func setBell(_ on: Bool) {
        guard !dead, on != bellActive else { return }
        bellActive = on
        header.setBell(on)
        refreshSignalVariant()
    }

    /// Live (agent-active) signal: a foreground process is running on a terminal
    /// card. Feeds the locard / minimap / offscreen-hint cyan variant.
    func setLive(_ on: Bool) {
        guard !dead, on != liveActive else { return }
        liveActive = on
        refreshSignalVariant()
    }

    // MARK: - Semantic-zoom locard (crib §7)

    private(set) var isLocard = false

    /// Toggles the locard rendering (crib §7): below the semantic-zoom threshold
    /// the body chrome is hidden and a compact name+status view is shown on the
    /// same world frame. The board calls this when the zoom crosses the
    /// threshold. `nameText` / `statusText` are the two rows; `kindGlyph` is the
    /// faint leading glyph; `repoColor` draws the optional repo dot (nil hides it).
    func setLocard(_ on: Bool) {
        guard on != isLocard else { return }
        isLocard = on
        if on {
            let lo = locard ?? makeLocard()
            locard = lo
            lo.isHidden = false
            clip.isHidden = true
            lo.frame = bounds
            applyLocardContent()
            refreshSignalVariant()
        } else {
            locard?.isHidden = true
            clip.isHidden = false
            // Restore the normal-card border for the current state.
            layer?.borderColor = currentBorderColor.cgColor
        }
        needsLayout = true
    }

    private func makeLocard() -> LocardView {
        let glyph: String
        switch id {
        case .term: glyph = "›_"
        case .doc: glyph = "¶"
        }
        let lo = LocardView(kindGlyph: glyph, showsRepoDot: { if case .doc = id { return true }; return false }())
        lo.isHidden = true
        // At semantic zoom the whole locard is the drag handle (the header chrome
        // is hidden), so a press anywhere on it moves/selects the card.
        lo.onMouseDown = { [weak self] event in self?.beginMove(event: event) }
        lo.onMouseDragged = { [weak self] event in self?.updateGesture(event) }
        lo.onMouseUp = { [weak self] _ in self?.endGesture(commit: true) }
        // The locard sits inside the rounded clip-equivalent: put it directly on
        // self (above the hidden chrome clip) but below the resize handles.
        addSubview(lo, positioned: .below, relativeTo: clip)
        return lo
    }

    /// The two-row content for the locard. Terminal cards show the foreground
    /// process name + duration as the status; doc cards show basename + recency.
    /// The board feeds the strings via `setLocardContent`.
    private var locardName = ""
    private var locardStatus = ""
    private var locardRepoColor: NSColor?

    func setLocardContent(name: String, status: String, repoColor: NSColor?) {
        locardName = name
        locardStatus = status
        locardRepoColor = repoColor
        if isLocard { applyLocardContent() }
    }

    private func applyLocardContent() {
        locard?.setContent(name: locardName, status: locardStatus, repoColor: locardRepoColor)
    }

    /// Applies the signal variant border/ring to the active rendering. On a
    /// locard the bell/live borders + ring come from crib §7; on a normal card
    /// the variant is carried by the header (bell) / fresh ring.
    private func refreshSignalVariant() {
        guard isLocard, let lo = locard else { return }
        lo.applySignal(signal)
        switch signal {
        case .bell: layer?.borderColor = Theme.amber.withAlphaComponent(0.55).cgColor
        case .live: layer?.borderColor = Theme.agent.withAlphaComponent(0.45).cgColor
        case .none: layer?.borderColor = currentBorderColor.cgColor
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        clip.frame = bounds
        locard?.frame = bounds
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        body.frame = NSRect(
            x: 0,
            y: Self.headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.headerHeight)
        )
        layoutHandles()
        layoutRing()
    }

    private func layoutHandles() {
        let hit = Self.handleHitSize
        let inset = Self.handleCornerInset
        for (corner, h) in handles {
            // Corner point nudged inward toward the card center (flipped view:
            // top corners at y≈0), then the hit box is centered on that point.
            let cx: CGFloat
            let cy: CGFloat
            switch corner {
            case .topLeft: cx = inset; cy = inset
            case .topRight: cx = bounds.width - inset; cy = inset
            case .bottomLeft: cx = inset; cy = bounds.height - inset
            case .bottomRight: cx = bounds.width - inset; cy = bounds.height - inset
            }
            h.frame = NSRect(x: cx - hit / 2, y: cy - hit / 2, width: hit, height: hit)
        }
    }

    // MARK: - Move (crib §5: free drag-to-move; lift shadow, no rotation)

    private func beginMove(event: NSEvent) {
        guard gesture == nil else { return }
        onSelectRequested?(self)
        gesture = .move(
            startWindow: event.locationInWindow,
            startWorldX: worldFrame.x,
            startWorldY: worldFrame.y
        )
        setLifted(true)
    }

    private func beginResize(corner: HandleCorner, event: NSEvent) {
        guard gesture == nil else { return }
        onSelectRequested?(self)
        gesture = .resize(corner: corner, startWindow: event.locationInWindow, startFrame: worldFrame)
        setLifted(true)
    }

    private func updateGesture(_ event: NSEvent) {
        guard let gesture else { return }
        switch gesture {
        case let .move(startWindow, startWorldX, startWorldY):
            let dxView = event.locationInWindow.x - startWindow.x
            let dyView = event.locationInWindow.y - startWindow.y
            // Window y is bottom-up; the board is flipped (top-down), so invert dy.
            worldFrame.x = startWorldX + dxView * worldPerView
            worldFrame.y = startWorldY - dyView * worldPerView
        case let .resize(corner, startWindow, startFrame):
            let dxView = event.locationInWindow.x - startWindow.x
            let dyView = event.locationInWindow.y - startWindow.y
            let dxW = dxView * worldPerView
            let dyW = -dyView * worldPerView
            worldFrame = Self.resized(startFrame, corner: corner, dxWorld: dxW, dyWorld: dyW)
        }
        onWorldFrameChangedDuringGesture?(self)
    }

    /// Live callback while a move/resize is in flight (board reprojects to view
    /// frame; terminal reflow is deferred to commit). Set by the board.
    var onWorldFrameChangedDuringGesture: ((CardView) -> Void)?

    private func endGesture(commit: Bool) {
        guard let gesture else { return }
        if case .move = gesture { lastCommittedGestureWasMove = true } else { lastCommittedGestureWasMove = false }
        self.gesture = nil
        setLifted(false)
        if commit { onFrameCommitted?(self) }
    }

    /// esc cancels an in-flight move/resize (crib §5 drag-cancel priority);
    /// returns false when no gesture is active so esc falls through. The board
    /// snapshots the pre-gesture frame and restores it.
    @discardableResult
    func cancelGesture(restoringTo frame: CardFrame?) -> Bool {
        guard gesture != nil else { return false }
        gesture = nil
        if let frame { worldFrame = frame }
        setLifted(false)
        return true
    }

    var hasActiveGesture: Bool { gesture != nil }

    private static func resized(
        _ start: CardFrame,
        corner: HandleCorner,
        dxWorld: CGFloat,
        dyWorld: CGFloat
    ) -> CardFrame {
        var x = start.x, y = start.y, w = start.w, h = start.h
        if corner.movesLeft {
            let nx = min(start.x + dxWorld, start.x + start.w - minWidth)
            w = start.w + (start.x - nx)
            x = nx
        } else {
            w = max(minWidth, start.w + dxWorld)
        }
        if corner.movesTop {
            let ny = min(start.y + dyWorld, start.y + start.h - minHeight)
            h = start.h + (start.y - ny)
            y = ny
        } else {
            h = max(minHeight, start.h + dyWorld)
        }
        return CardFrame(x: x, y: y, w: w, h: h, z: start.z)
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

    private func setLifted(_ on: Bool) {
        guard on != lifted, let layer else { return }
        lifted = on
        if on {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = Theme.liftBorder.cgColor
            layer.zPosition = 1
            CATransaction.commit()
            // Deeper than the resting base while a drag/resize is held.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = NSSize(width: 0, height: -18)
            shadow.shadowBlurRadius = 22
            self.shadow = shadow
        } else {
            layer.zPosition = 0
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

/// Which corner a resize handle drives.
enum HandleCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { self == .topLeft || self == .bottomLeft }
    var movesTop: Bool { self == .topLeft || self == .topRight }

    var cursor: NSCursor {
        // AppKit ships no diagonal resize cursor publicly; crosshair reads as
        // "grab to resize" without private API.
        .crosshair
    }
}

/// Selection resize handle (crib §4). The view itself is a larger transparent
/// hit/cursor target (`CardView.handleHitSize`); the visible 7×7 square — fill
/// bg0, 1.5px agent border, radius 2 — is drawn by `chip`, centered inside it.
/// Owns its own mouse so a press on a handle resizes rather than moves the card.
@MainActor
final class ResizeHandleView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    private let corner: HandleCorner
    private let chip = CALayer()

    override var acceptsFirstResponder: Bool { false }

    init(corner: HandleCorner) {
        self.corner = corner
        super.init(frame: .zero)
        wantsLayer = true
        chip.backgroundColor = Theme.bg0.cgColor
        chip.borderColor = Theme.agent.cgColor
        chip.borderWidth = 1.5
        chip.cornerRadius = 2
        layer?.addSublayer(chip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let s = CardView.handleSize
        // Center the visible square in the larger transparent hit box; no
        // implicit animation so it doesn't lag the card during a resize drag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.frame = NSRect(
            x: (bounds.width - s) / 2,
            y: (bounds.height - s) / 2,
            width: s,
            height: s
        )
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: corner.cursor)
    }
}

/// A card's wayfinding signal (crib §6–7), shared by the locard / minimap /
/// offscreen hints. `bell` (amber) outranks `live` (cyan) when both are set.
enum CardSignal: Equatable {
    case none
    case live
    case bell
}

/// Semantic-zoom locard (crib §7): "content gone, name + signal remain". A
/// compact two-row card on bg1 (radius 8) — a name row (kind glyph faint +
/// optional repo dot + name, 12px mono weight 500) and a status row (one signal
/// line, 9.5px mono faint). Lives inside `CardView` and is shown below the
/// semantic-zoom threshold in place of the chrome.
@MainActor
final class LocardView: NSView {
    private let kindGlyph: NSTextField
    private let repoDot: NSView?
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// Bell ring (crib §7: `0 0 0 3px amber-dim`); built on demand.
    private let ringLayer = CALayer()
    private static let ringWidth: CGFloat = 3
    private var ringOn = false

    // The whole locard is the drag handle at semantic zoom (crib §7); the parent
    // CardView wires these to its move gesture.
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    // Capture the whole locard area (labels would otherwise swallow mouseDown).
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    init(kindGlyph glyph: String, showsRepoDot: Bool) {
        kindGlyph = NSTextField(labelWithString: glyph)
        repoDot = showsRepoDot ? NSView() : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = false

        kindGlyph.font = Theme.mono(12)
        kindGlyph.textColor = Theme.faint
        addSubview(kindGlyph)

        if let repoDot {
            repoDot.wantsLayer = true
            repoDot.layer?.cornerRadius = 3.5
            addSubview(repoDot)
        }

        nameLabel.font = Theme.mono(12, weight: .medium)
        nameLabel.textColor = Theme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        statusLabel.font = Theme.mono(9.5)
        statusLabel.textColor = Theme.faint
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setContent(name: String, status: String, repoColor: NSColor?) {
        nameLabel.stringValue = name
        statusLabel.stringValue = status
        if let repoColor { repoDot?.layer?.backgroundColor = repoColor.cgColor }
        needsLayout = true
    }

    /// Applies the locard signal variant (crib §7): bell = amber-dim ring; live
    /// has only a border (set by the parent CardView). `none` clears the ring.
    func applySignal(_ signal: CardSignal) {
        let bell = signal == .bell
        guard bell != ringOn, let layer else { return }
        ringOn = bell
        if bell {
            ringLayer.backgroundColor = Theme.amberDim.cgColor
            ringLayer.cornerRadius = 8 + Self.ringWidth
            layer.insertSublayer(ringLayer, at: 0)
        } else {
            ringLayer.removeFromSuperlayer()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if ringOn {
            let w = Self.ringWidth
            ringLayer.frame = bounds.insetBy(dx: -w, dy: -w)
        }
        // Two centered rows (crib §7: justify-content center, gap 5, padding 0 14).
        let padX: CGFloat = 14
        let gap: CGFloat = 5
        let nameH = nameLabel.fittedSize.height
        let statusH = statusLabel.fittedSize.height
        let totalH = nameH + gap + statusH
        let topY = ((bounds.height - totalH) / 2).rounded()

        var x = padX
        let glyphSize = kindGlyph.fittedSize
        kindGlyph.frame = NSRect(x: x, y: topY + ((nameH - glyphSize.height) / 2).rounded(), width: glyphSize.width, height: glyphSize.height)
        x = kindGlyph.frame.maxX + 7
        if let repoDot {
            repoDot.frame = NSRect(x: x, y: topY + ((nameH - 7) / 2).rounded(), width: 7, height: 7)
            x += 7 + 7
        }
        nameLabel.frame = NSRect(x: x, y: topY, width: max(0, bounds.width - padX - x), height: nameH)
        statusLabel.frame = NSRect(x: padX, y: topY + nameH + gap, width: max(0, bounds.width - padX * 2), height: statusH)
    }
}
