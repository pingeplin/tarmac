import AppKit
import QuartzCore
import TarmacKit

/// A free card on the board (crib §4) — the v4 successor to `TileView`. Same
/// chrome family (reuses `TileHeaderView` / `RecentMetaLabel` / `TerminalBodyView`
/// / `DocWebView`), but a card carries a *world frame* instead of a grid slot,
/// drags to MOVE (no slot swap, no −0.5° rotation — keeps the lift shadow), and
/// shows 7px corner resize handles when selected.
///
/// Metrics differ from `TileView` per crib §4: header **30px**, radius **10**.
/// `.tm-bcard` is `overflow:hidden`, so the selection handles live on the
/// non-clipped outer view (`self`), above the inner rounded clip.
///
/// 2c hosts these inside `BoardView`; this phase the type is unused so the app
/// stays green.
@MainActor
final class CardView: NSView {
    static let headerHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 10
    /// Handle is 7×7 offset −4 outside the edge (crib §4): spans −4..+3.
    static let handleSize: CGFloat = 7
    static let handleOffset: CGFloat = 4
    /// Below this card size a resize can't go (header + a sliver of body).
    static let minWidth: CGFloat = 160
    static let minHeight: CGFloat = 90

    let id: CardID
    let header: TileHeaderView
    private(set) var docView: DocWebView?
    private(set) var termBody: TerminalBodyView?

    /// World-space placement (crib §5). Set by `BoardView` on add / drag / resize;
    /// the on-screen `frame` is derived from this by the board's world→view map.
    var worldFrame: CardFrame

    /// Fires the moment a MOVE or RESIZE commits (mouse-up), so the board can
    /// persist the new world frame and reflow the terminal. The board sets this.
    var onFrameCommitted: ((CardView) -> Void)?
    /// Header mouse-down requesting selection/raise before a move begins.
    var onSelectRequested: ((CardView) -> Void)?

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
            header = TileHeaderView(kindGlyph: "›_", showsRepoDot: false, unpinButton: nil)
            let term = TerminalBodyView()
            termBody = term
            body = term
        case .doc:
            header = TileHeaderView(kindGlyph: "¶", showsRepoDot: true, unpinButton: nil)
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content (mirrors TileView's surface so 2c wires it the same way)

    func attachTerminal(_ terminal: NSView) {
        termBody?.attach(terminal)
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

    // MARK: - Selection

    func setSelected(_ on: Bool) {
        // Selecting a fresh card clears the fresh ring (crib §5).
        if on && fresh { setFresh(false) }
        guard on != selected else { return }
        selected = on
        layer?.borderColor = currentBorderColor.cgColor
        for h in handles.values { h.isHidden = !on }
    }

    /// The base border color for the current state: agent when selected or
    /// fresh, else line (the lift state overrides this transiently).
    private var currentBorderColor: NSColor {
        (selected || fresh) ? Theme.agent : Theme.line
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

    /// Amber bell signal in the header (a `●` dot + amber kind-glyph accent),
    /// shown on a seen BEL and cleared on the next keystroke / focus. Display
    /// state only — no animation (stays under Reduce Motion).
    func setBell(_ on: Bool) {
        guard on != bellActive else { return }
        bellActive = on
        header.setBell(on)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        clip.frame = bounds
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
        let s = Self.handleSize
        let o = Self.handleOffset
        for (corner, h) in handles {
            let origin: NSPoint
            switch corner {
            case .topLeft: origin = NSPoint(x: -o, y: -o)
            case .topRight: origin = NSPoint(x: bounds.width - s + o, y: -o)
            case .bottomLeft: origin = NSPoint(x: -o, y: bounds.height - s + o)
            case .bottomRight: origin = NSPoint(x: bounds.width - s + o, y: bounds.height - s + o)
            }
            h.frame = NSRect(origin: origin, size: CGSize(width: s, height: s))
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
    /// grid rather than flat panes. The lift deepens it; un-lift returns here.
    private func applyRestingShadow() {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -16)
        shadow.shadowBlurRadius = 19
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

/// 7×7 selection resize handle (crib §4): fill bg0, 1.5px agent border, radius 2.
/// Owns its own mouse so a press on a handle resizes rather than moves the card.
@MainActor
final class ResizeHandleView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    private let corner: HandleCorner

    override var acceptsFirstResponder: Bool { false }

    init(corner: HandleCorner) {
        self.corner = corner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor
        layer?.borderColor = Theme.agent.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 2
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: corner.cursor)
    }
}
