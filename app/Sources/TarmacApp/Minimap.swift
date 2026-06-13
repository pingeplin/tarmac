import AppKit
import TarmacKit

/// Minimap (crib §6, Phase 4): a bottom-right 132×88 overview. bg rgba(36,40,44,
/// 0.92), 1px line border, radius 8, clipped. Maps the world bbox of all cards
/// (plus the current viewport rect) into the 132×88 area; each card is a small
/// radius-1.5 rect colored by its signal (default bg3, live cyan@0.8, bell
/// amber@0.85). The viewport rect is a 1px agent border + agentDim fill, radius 2.
/// A click maps back to a world point and re-centers the viewport.
@MainActor
final class Minimap: NSView {
    /// One card in the minimap: its world frame + signal (for the rect color).
    struct Item {
        var worldRect: CGRect
        var signal: CardSignal
    }

    static let mapWidth: CGFloat = 132
    static let mapHeight: CGFloat = 88
    private static let pad: CGFloat = 6

    /// Re-center the viewport on this world point (a click landed here).
    var onJump: ((CGPoint) -> Void)?

    private var items: [Item] = []
    private var viewportWorldRect: CGRect = .zero
    private var mapping: BoardWayfinding.MinimapMapping?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.mapWidth, height: Self.mapHeight))
        wantsLayer = true
        // bg0 @ 0.92 (crib §1: minimap bg).
        layer?.backgroundColor = Theme.bg0.withAlphaComponent(0.92).cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Updates the minimap from the current card frames + viewport world rect.
    /// The world bbox unions the cards and the viewport so the viewport rect is
    /// always visible (panning beyond the cards still shows where you are).
    func update(items: [Item], viewportWorldRect: CGRect) {
        self.items = items
        self.viewportWorldRect = viewportWorldRect
        recomputeMapping()
        needsDisplay = true
    }

    private func recomputeMapping() {
        var rects = items.map(\.worldRect)
        rects.append(viewportWorldRect)
        guard let box = BoardWayfinding.boundingBox(of: rects) else {
            mapping = nil
            return
        }
        mapping = BoardWayfinding.minimapMapping(
            worldBox: box,
            minimapSize: CGSize(width: Self.mapWidth, height: Self.mapHeight),
            pad: Self.pad
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mapping else { return }
        for item in items {
            let r = mapping.toMinimap(item.worldRect)
            let color: NSColor
            switch item.signal {
            case .live: color = Theme.agent.withAlphaComponent(0.8)
            case .bell: color = Theme.amber.withAlphaComponent(0.85)
            case .none: color = Theme.bg3
            }
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
        // Viewport rect: agentDim fill + 1px agent border, radius 2 (crib §6).
        let vp = mapping.toMinimap(viewportWorldRect)
        let vpPath = NSBezierPath(roundedRect: vp.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        Theme.agentDim.setFill()
        vpPath.fill()
        Theme.agent.setStroke()
        vpPath.lineWidth = 1
        vpPath.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let mapping else { return }
        let local = convert(event.locationInWindow, from: nil)
        let world = mapping.toWorld(local)
        onJump?(world)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
