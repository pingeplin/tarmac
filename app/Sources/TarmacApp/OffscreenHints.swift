import AppKit
import TarmacKit

/// The edge pills: one per signalling card whose centre is off screen, pinned
/// to the viewport edge towards it. `OffscreenHintLayout` decides where each
/// goes; this measures them, draws them, and sorts them onto two layers — a
/// pill that found room goes over the cards, one that could not clear a card
/// goes under them, so it never covers what the card shows.
@MainActor
final class OffscreenHints {
    /// Sits over every card.
    let over = OffscreenHintLayer()
    /// Belongs inside the board, over its edges and under its cards.
    let under = OffscreenHintLayer()

    private static let edgeInset: CGFloat = 18
    private static let edgeMargin: CGFloat = 10
    private static let stackGap: CGFloat = 8

    private var pills: [String: OffscreenHintPill] = [:]
    /// A pill was clicked, with the id of the terminal it stands for.
    var onClick: ((String) -> Void)?

    /// A pill is measured once, for the font it was built with: after a font
    /// change the next `show` builds every pill again.
    func forget() {
        pills.values.forEach { $0.removeFromSuperview() }
        pills = [:]
    }

    /// Shows a pill for each of `hints`, and returns them as placed.
    /// `viewRect` is the part of the board's bounds left uncovered and
    /// `obstacles` its cards' on-screen rects, and `chrome` the corner chrome
    /// drawn over the pills (`OverlayStack.pillChrome`); all in the board's
    /// coordinates, which both layers share.
    @discardableResult
    func show(
        _ hints: [OffscreenHintLayout.Hint], in viewRect: CGRect, around obstacles: [CGRect], clearOf chrome: [CGRect]
    ) -> [OffscreenHintLayout.PlacedPill] {
        var next: [String: OffscreenHintPill] = [:]
        for hint in hints {
            guard let placement = BoardWayfinding.hintPlacement(
                cardCenterView: hint.centerView, viewRect: viewRect, inset: Self.edgeInset
            ) else { continue }
            let content = OffscreenHintPill.Content(arrow: placement.edge.arrow, label: hint.label, signal: hint.signal)
            let pill = pills[hint.cardID]
            next[hint.cardID] = pill?.content == content ? pill : makePill(content, cardID: hint.cardID)
        }
        for (cardID, pill) in pills where next[cardID] !== pill { pill.removeFromSuperview() }
        pills = next

        let sizes = pills.mapValues(\.size)
        let placed = OffscreenHintLayout.stackPills(hints, in: viewRect, options: OffscreenHintLayout.Options(
            edgeInset: Self.edgeInset,
            edgeMargin: Self.edgeMargin,
            stackGap: Self.stackGap,
            pillSize: { sizes[$0.cardID] ?? .zero },
            obstacles: obstacles,
            chrome: chrome
        ))
        for position in placed {
            guard let pill = pills[position.cardID] else { continue }
            pill.frame = NSRect(origin: CGPoint(x: position.left, y: position.top), size: pill.size)
            let layer = position.occluded ? under : over
            if pill.superview !== layer { layer.addSubview(pill) }
        }
        return placed
    }

    private func makePill(_ content: OffscreenHintPill.Content, cardID: String) -> OffscreenHintPill {
        let pill = OffscreenHintPill(content)
        pill.onClick = { [weak self] in self?.onClick?(cardID) }
        return pill
    }
}

/// A board-sized sheet of pills. Click-through between the pills, and clipped
/// to the board so a pill's shadow never falls on the status bar.
@MainActor
final class OffscreenHintLayer: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One pill: an arrow and a label in a fully rounded border box, coloured by
/// the signal it stands for. A click on it jumps to its card.
@MainActor
final class OffscreenHintPill: PressControl {
    struct Content: Equatable {
        var arrow: String
        var label: InlineText
        var signal: CardSignal
    }

    private static let insetX: CGFloat = 1 + 11
    private static let insetY: CGFloat = 1 + 6
    private static let gap: CGFloat = 7
    private static let fontSize: CGFloat = 10.5

    let content: Content
    let size: NSSize

    override var isFlipped: Bool { true }

    init(_ content: Content) {
        self.content = content
        let arrow = ChromeLabel(content.arrow, size: Self.fontSize, color: OverlayPalette.hintArrow(content.signal))
        let label = InlineTextLabel(style: InlineTextLabel.Style(
            design: Self.fontSize, color: OverlayPalette.hintLabel(content.signal), boxFill: Theme.bg1, boxBorder: Theme.line
        ))
        label.text = content.label
        let arrowSize = arrow.textSize
        let labelSize = label.naturalSize
        size = NSSize(
            width: (2 * Self.insetX + arrowSize.width + Self.gap + labelSize.width).rounded(.up),
            height: 2 * Self.insetY + arrow.lineHeight
        )
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = OverlayPalette.hintBorder(content.signal).cgColor
        layer?.cornerRadius = size.height / 2
        shadow = OverlayPalette.hintShadow

        arrow.place(at: CGPoint(x: Self.insetX, y: Self.insetY))
        addSubview(arrow)
        label.frame = NSRect(
            origin: CGPoint(x: (Self.insetX + arrowSize.width + Self.gap).rounded(), y: Self.insetY),
            size: NSSize(width: labelSize.width.rounded(.up), height: labelSize.height)
        )
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
