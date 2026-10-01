import AppKit
import TarmacKit

/// The provenance edges, drawn beneath the cards: one dashed segment per doc,
/// from the terminal that opened it. The board hands in the segments already
/// in its own coordinates and again on every pan, zoom and drag.
@MainActor
final class EdgeLayerView: NSView {
    private var edges: [Provenance.Segment] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setEdges(_ edges: [Provenance.Segment]) {
        guard edges != self.edges else { return }
        self.edges = edges
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setStrokeColor(Theme.agent.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 5])
        for edge in edges {
            context.move(to: edge.from)
            context.addLine(to: edge.to)
        }
        context.strokePath()
    }
}
