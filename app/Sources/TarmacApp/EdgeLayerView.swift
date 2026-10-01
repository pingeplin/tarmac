import AppKit
import QuartzCore
import TarmacKit

/// Provenance edge layer (crib §8): an SVG-equivalent layer drawn BENEATH the
/// cards (backmost; z 0). For each doc card whose owning term card is present,
/// it draws a dashed cyan cubic bézier from the caller term card's right-edge
/// midpoint to the doc card's left-edge midpoint, plus an optional
/// `tarmac open · HH:MM` label chip near the start.
///
/// All geometry is in this view's (view-space) coordinates — `BoardView` feeds
/// already-projected card rects, so edges survive pan / zoom / drag by being
/// recomputed on every reproject.
@MainActor
final class EdgeLayerView: NSView {
    /// One provenance edge: a caller term card → doc card pairing in view space,
    /// with the label time (HH:MM from the doc's lastOpenedMs, local).
    struct Edge {
        var callerRect: CGRect
        var docRect: CGRect
        var label: String?
    }

    private var edges: [Edge] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    // Click-through: the edge layer never intercepts mouse events (crib §8
    // pointer-events: none).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setEdges(_ edges: [Edge]) {
        self.edges = edges
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // crib §8: stroke rgba(26,188,156,0.5), width 1.2, dash [3,5], fill none.
        let stroke = Theme.agent.withAlphaComponent(0.5)
        for edge in edges {
            let start = CGPoint(x: edge.callerRect.maxX, y: edge.callerRect.midY)
            let end = CGPoint(x: edge.docRect.minX, y: edge.docRect.midY)
            // Control points biased horizontally for a near-horizontal swoosh:
            // larger dx, small dy (crib §8). Push each control point ~45% of the
            // horizontal span toward the destination.
            let dx = end.x - start.x
            let cp1 = CGPoint(x: start.x + dx * 0.5, y: start.y + (end.y - start.y) * 0.15)
            let cp2 = CGPoint(x: start.x + dx * 0.55, y: start.y + (end.y - start.y) * 0.55)

            let path = CGMutablePath()
            path.move(to: start)
            path.addCurve(to: end, control1: cp1, control2: cp2)

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [3, 5])
            ctx.strokePath()
            ctx.restoreGState()

            if let label = edge.label {
                drawLabel(label, near: start)
            }
        }
    }

    /// `.tm-edgelab` (crib §8): mono 9px faint, bg0, padding 1px 6px, radius 4,
    /// placed just past the edge start (behind the cards by z-order).
    private func drawLabel(_ text: String, near start: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(9),
            .foregroundColor: Theme.faint,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        let padX: CGFloat = 6
        let padY: CGFloat = 1
        let w = (textSize.width + padX * 2).rounded()
        let h = (textSize.height + padY * 2).rounded()
        // Sit just below the start point so it does not overdraw the caller card.
        let origin = CGPoint(x: (start.x + 6).rounded(), y: (start.y + 4).rounded())
        let chip = NSRect(x: origin.x, y: origin.y, width: w, height: h)

        let bg = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
        Theme.bg0.setFill()
        bg.fill()
        attr.draw(at: CGPoint(x: chip.minX + padX, y: chip.minY + padY))
    }
}
