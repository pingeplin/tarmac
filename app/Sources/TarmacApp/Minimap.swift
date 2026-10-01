import AppKit
import TarmacKit

/// The board's bottom-right overview: every card as a small rect coloured by
/// its signal, and the viewport as a box, both mapped from the bounding box of
/// the cards and the visible region so the box stays in the picture however
/// far the board is panned. A click re-centers the viewport on the world point
/// under it.
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
        layer?.backgroundColor = OverlayPalette.minimapBackground.cgColor
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
            OverlayPalette.minimapFill(item.signal).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
        // Inset by half the stroke, so the 1px line lands inside the box.
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
}

extension Minimap: HoverCursorProviding {
    func hoverCursor(at windowPoint: NSPoint) -> NSCursor { .pointingHand }
    /// A terminal under the minimap would answer the same move with its I-beam.
    var claimsPointerMoves: Bool { true }
}
