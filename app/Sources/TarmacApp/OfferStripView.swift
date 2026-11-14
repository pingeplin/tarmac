import AppKit
import TarmacKit

/// A terminal card's offer (spec 2611.0011): the resume chip, or a dead card's
/// `↻ reopen here  ⏎`. It is pinned to the bottom of the card's body, over the
/// content, and wraps inside the card's width, so no part of a command is
/// clipped. It uses the report chip's metrics: a bordered mono text, laid out
/// at the board's zoom.
///
/// It is a sibling of its card in the board's card layer, stacked just above
/// it, not a subview: a dead card dims itself with `alphaValue`, which would
/// dim every subview, and the offer is drawn at full opacity.
@MainActor
final class OfferStripView: NSView, ThemeFollowing {
    private static let fontSize: CGFloat = 9
    private static let padX: CGFloat = 6
    private static let padY: CGFloat = 3
    private static let cornerRadius: CGFloat = 4
    private static let inset: CGFloat = 6

    /// The card it belongs to, which places it and stacks it.
    private(set) weak var card: CardView?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var scale = CardScale(zoom: 1, backing: 2)
    /// The press of a reopen offer; nil for the resume chip, which takes none.
    var onPress: (() -> Void)?
    /// The whole command, verbatim. A tool tip rect, as the header gives its
    /// report chip, since the resume chip takes no hit.
    private var tip: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(card: CardView) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        addSubview(label)
        themeChanged()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func themeChanged() {
        layer?.borderColor = Theme.lineSoft.cgColor
        layer?.backgroundColor = Theme.termBg.cgColor
        label.textColor = Theme.text
    }

    func show(lines: [String], toolTip: String?) {
        label.stringValue = lines.joined(separator: "\n")
        tip = toolTip
    }

    func apply(_ scale: CardScale) {
        self.scale = scale
        label.font = Theme.mono(scale.length(Self.fontSize))
        layer?.cornerRadius = scale.length(Self.cornerRadius)
        layer?.borderWidth = scale.line(1)
    }

    /// Lays the strip out along the bottom of `body`, a rect in the card
    /// layer's coordinates, as tall as its wrapped text.
    func place(along body: CGRect) {
        let inset = scale.length(Self.inset), padX = scale.length(Self.padX), padY = scale.length(Self.padY)
        let width = max(0, body.width - 2 * inset)
        let textWidth = max(0, width - 2 * padX)
        let textHeight = ceil(label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let height = min(textHeight + 2 * padY, body.height)
        frame = NSRect(x: body.minX + inset, y: body.maxY - inset - height, width: width, height: height)
        label.frame = NSRect(x: padX, y: padY, width: textWidth, height: textHeight)
        removeAllToolTips()
        if tip != nil { addToolTip(bounds, owner: self, userData: nil) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        onPress == nil ? nil : super.hitTest(point).map { _ in self }
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }
}

extension OfferStripView: NSViewToolTipOwner {
    nonisolated func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        MainActor.assumeIsolated { tip ?? "" }
    }
}
