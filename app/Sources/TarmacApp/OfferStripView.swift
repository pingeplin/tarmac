import AppKit
import TarmacKit

/// A terminal card's offer (spec 2611.0011): the resume chip, or a dead card's
/// `↻ reopen here  ⏎`. It is pinned to the bottom of the card's body, over the
/// content, and wraps inside the card's width, so no part of a command is
/// clipped. It uses the chip metrics (`ChipMetrics`), laid out at the board's
/// zoom, with a fill: it is opaque chrome over terminal text.
///
/// It is a sibling of its card in the board's card layer, stacked just above
/// it, not a subview: a dead card dims itself with `alphaValue`, which would
/// dim every subview, and the offer is drawn at full opacity.
@MainActor
final class OfferStripView: NSView, ThemeFollowing {
    private static let inset: CGFloat = 6

    /// What the strip was last measured for; a pan moves it only.
    private struct Measured: Equatable {
        let bodySize: CGSize
        let scale: CardScale
        let text: String
        let tip: String?
    }

    private var measured: Measured?
    private var height: CGFloat = 0

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
        label.font = Theme.mono(scale.length(ChipMetrics.fontSize))
        layer?.cornerRadius = scale.length(ChipMetrics.cornerRadius)
        layer?.borderWidth = scale.line(1)
    }

    /// Lays the strip out along the bottom of `body`, a rect in the card
    /// layer's coordinates, as tall as its wrapped text. The text is measured
    /// and the tool tip set again only when what they depend on changed.
    func place(along body: CGRect) {
        let inset = scale.length(Self.inset)
        let width = max(0, body.width - 2 * inset)
        let now = Measured(bodySize: body.size, scale: scale, text: label.stringValue, tip: tip)
        if now != measured {
            measured = now
            let padX = scale.length(ChipMetrics.padX), padY = scale.length(ChipMetrics.padY)
            let textWidth = max(0, width - 2 * padX)
            let textHeight = ceil(label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            height = min(textHeight + 2 * padY, body.height)
            label.frame = NSRect(x: padX, y: padY, width: textWidth, height: textHeight)
            frame.size = NSSize(width: width, height: height)
            removeAllToolTips()
            if tip != nil { addToolTip(bounds, owner: self, userData: nil) }
        }
        frame.origin = NSPoint(x: body.minX + inset, y: body.maxY - inset - height)
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
