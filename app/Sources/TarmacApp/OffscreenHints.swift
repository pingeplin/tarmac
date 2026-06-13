import AppKit
import TarmacKit

/// Offscreen signal hints (crib §6, Phase 4): for each card OUTSIDE the viewport
/// that has a signal, a pill pinned to the viewport edge toward the card — a
/// direction arrow (`→ ← ↑ ↓`, faint) + a short label (basename · HH:MM for bell,
/// or the live process name). Pills stack along the edges without overlap.
///
/// The overlay is board-sized and click-through; it owns only the pill layout.
/// `Return` flight + `esc` fly-back are driven by the controller (which reads
/// `targetCardID` for the most-recent/active signal).
@MainActor
final class OffscreenHints: NSView {
    /// One offscreen-card hint the overlay should consider drawing.
    struct Hint {
        var cardID: CardID
        /// The card's center in this overlay's (view-space) coordinates.
        var centerView: CGPoint
        var signal: CardSignal
        var label: String
        /// Higher = more recent / active; the Return target is the max.
        var priority: Int
    }

    private var hints: [Hint] = []
    private var pills: [OffscreenHintPill] = []

    /// The card the Return flight should fly to (the highest-priority visible
    /// hint), or nil when there are no offscreen-signal cards.
    private(set) var targetCardID: CardID?

    /// Inset so pills don't sit on the very corner (crib §6 stacking).
    private static let edgeInset: CGFloat = 18
    private static let edgeMargin: CGFloat = 10
    private static let stackGap: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    // Click-through: hints never intercept the board's mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rebuilds the visible pill set from the current hints + the visible view
    /// rect (the board's bounds in this overlay's space — the same coordinates).
    func update(hints: [Hint], viewRect: CGRect) {
        self.hints = hints
        rebuild(viewRect: viewRect)
    }

    private func rebuild(viewRect: CGRect) {
        for pill in pills { pill.removeFromSuperview() }
        pills = []

        // Compute a placement for each offscreen-signal hint; keep the highest
        // priority as the Return target.
        var placed: [(Hint, BoardWayfinding.HintPlacement)] = []
        var best: Hint?
        for hint in hints where hint.signal != .none {
            guard let placement = BoardWayfinding.hintPlacement(
                cardCenterView: hint.centerView,
                viewRect: viewRect,
                inset: Self.edgeInset
            ) else { continue }
            placed.append((hint, placement))
            if best == nil || hint.priority > best!.priority { best = hint }
        }
        targetCardID = best?.cardID

        // Build the pills, then stack per edge so they don't overlap.
        var byEdge: [BoardWayfinding.Edge: [(OffscreenHintPill, CGFloat)]] = [:]
        for (hint, placement) in placed {
            let pill = OffscreenHintPill(arrow: placement.edge.arrow, label: hint.label, signal: hint.signal)
            addSubview(pill)
            pills.append(pill)
            byEdge[placement.edge, default: []].append((pill, placement.along))
        }
        for (edge, group) in byEdge {
            layout(edge: edge, group: group, viewRect: viewRect)
        }
    }

    /// Positions a group of pills along one edge, nudging later pills to avoid
    /// overlap with earlier ones (simple greedy stack along the edge axis).
    private func layout(
        edge: BoardWayfinding.Edge,
        group: [(OffscreenHintPill, CGFloat)],
        viewRect: CGRect
    ) {
        let sorted = group.sorted { $0.1 < $1.1 }
        let m = Self.edgeMargin
        var lastEnd: CGFloat = -.greatestFiniteMagnitude
        for (pill, along) in sorted {
            let size = pill.intrinsicContentSize
            switch edge {
            case .left, .right:
                var y = (along - size.height / 2)
                if y < lastEnd + Self.stackGap { y = lastEnd + Self.stackGap }
                y = min(y, viewRect.maxY - size.height - m)
                y = max(y, viewRect.minY + m)
                let x = edge == .left ? viewRect.minX + m : viewRect.maxX - size.width - m
                pill.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
                lastEnd = pill.frame.maxY
            case .top, .bottom:
                var x = (along - size.width / 2)
                if x < lastEnd + Self.stackGap { x = lastEnd + Self.stackGap }
                x = min(x, viewRect.maxX - size.width - m)
                x = max(x, viewRect.minX + m)
                let y = edge == .top ? viewRect.minY + m : viewRect.maxY - size.height - m
                pill.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
                lastEnd = pill.frame.maxX
            }
        }
    }
}

/// One offscreen-hint pill (crib §6): bg2, 1px border, radius 999 (full pill),
/// padding 6 11, 10.5px mono muted, shadow 0 8px 22px rgba(0,0,0,0.5). The bell
/// variant has an amber border + text + amber arrow; the live variant a cyan
/// border. The arrow is faint by default.
@MainActor
final class OffscreenHintPill: NSView {
    private let arrowLabel: NSTextField
    private let textLabel: NSTextField
    private var size: NSSize = .zero

    private static let padX: CGFloat = 11
    private static let padY: CGFloat = 6
    private static let gap: CGFloat = 7

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(arrow: String, label: String, signal: CardSignal) {
        arrowLabel = NSTextField(labelWithString: arrow)
        textLabel = NSTextField(labelWithString: label)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderWidth = 1

        let textColor: NSColor
        let arrowColor: NSColor
        switch signal {
        case .bell:
            layer?.borderColor = Theme.amber.withAlphaComponent(0.5).cgColor
            textColor = Theme.text
            arrowColor = Theme.amber
        case .live:
            layer?.borderColor = Theme.agent.withAlphaComponent(0.4).cgColor
            textColor = Theme.muted
            arrowColor = Theme.faint
        case .none:
            layer?.borderColor = Theme.line.cgColor
            textColor = Theme.muted
            arrowColor = Theme.faint
        }

        arrowLabel.font = Theme.mono(10.5)
        arrowLabel.textColor = arrowColor
        addSubview(arrowLabel)

        textLabel.font = Theme.mono(10.5)
        textLabel.textColor = textColor
        addSubview(textLabel)

        // shadow 0 8px 22px rgba(0,0,0,0.5) (crib §6).
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowBlurRadius = 22
        self.shadow = shadow

        let arrowSize = arrowLabel.fittedSize
        let textSize = textLabel.fittedSize
        let contentH = max(arrowSize.height, textSize.height)
        let w = Self.padX + arrowSize.width + Self.gap + textSize.width + Self.padX
        let h = Self.padY * 2 + contentH
        size = NSSize(width: w.rounded(), height: h.rounded())
        // radius 999 → a full pill (clamp to half-height).
        layer?.cornerRadius = h / 2
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { size }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = Self.padX
        let arrowSize = arrowLabel.fittedSize
        arrowLabel.frame = NSRect(x: x, y: ((h - arrowSize.height) / 2).rounded(), width: arrowSize.width, height: arrowSize.height)
        x += arrowSize.width + Self.gap
        let textSize = textLabel.fittedSize
        textLabel.frame = NSRect(x: x, y: ((h - textSize.height) / 2).rounded(), width: textSize.width, height: textSize.height)
    }
}
