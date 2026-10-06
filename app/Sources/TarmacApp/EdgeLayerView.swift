import AppKit
import QuartzCore
import TarmacKit

/// The provenance edges, drawn beneath the cards: one dashed segment per doc,
/// from the terminal that opened it. The board hands in the segments already
/// in its own coordinates and again on every pan, zoom and drag.
///
/// The segments are a shape layer's path, not a drawn bitmap: a backing store
/// the size of the board, redrawn on every one of those events, cost about
/// 5 ms an event in a full-screen window.
@MainActor
final class EdgeLayerView: NSView, ThemeFollowing {
    private var edges: [Provenance.Segment] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func makeBackingLayer() -> CALayer {
        let shape = CAShapeLayer()
        shape.fillColor = nil
        shape.lineWidth = 1.5
        shape.lineDashPattern = [5, 5]
        return shape
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        themeChanged()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func themeChanged() {
        (layer as? CAShapeLayer)?.strokeColor = Theme.agent.withAlphaComponent(0.7).cgColor
    }

    /// AppKit leaves a backing layer it did not make at 1×, where the dashes
    /// would be rasterised at half a Retina display's density.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
    }

    func setEdges(_ edges: [Provenance.Segment]) {
        guard edges != self.edges else { return }
        self.edges = edges
        let path = CGMutablePath()
        for edge in edges {
            path.move(to: edge.from)
            path.addLine(to: edge.to)
        }
        (layer as? CAShapeLayer)?.path = path
    }
}
