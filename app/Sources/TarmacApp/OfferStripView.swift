import AppKit
import TarmacKit

/// A terminal card's offer: the resume panel (spec 2611.0015 D9) — a title, the
/// whole command and its `resume` and `skip` buttons — or a dead card's
/// `reopen here  ⏎` strip (2611.0011). It is pinned to the bottom of the card's
/// body, over the content, and wraps inside the card's width, so no part of a
/// command is clipped. It uses the chip metrics (`ChipMetrics`), laid out at
/// the board's zoom, with a fill: it is opaque chrome over terminal text.
///
/// It is a sibling of its card in the board's card layer, stacked just above
/// it, not a subview: a dead card dims itself with `alphaValue`, which would
/// dim every subview, and the offer is drawn at full opacity.
@MainActor
final class OfferStripView: NSView, ThemeFollowing {
    private static let inset: CGFloat = 6
    private static let buttonGap: CGFloat = 6

    /// What the strip was last measured for; a pan moves it only.
    private struct Measured: Equatable {
        let bodySize: CGSize
        let scale: CardScale
        let text: String
        let buttons: [String]
    }

    private var measured: Measured?
    private var height: CGFloat = 0

    /// The card it belongs to, which places it and stacks it.
    private(set) weak var card: CardView?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var scale = CardScale(zoom: 1, backing: 2)
    /// The press of a reopen offer, which makes the whole strip a button; nil
    /// for the resume panel, whose buttons alone take a press.
    var onPress: (() -> Void)?
    private var title: String?
    private var buttons: [(choice: ResumePanel.Choice, view: ChipView)] = []
    private var buttonTexts: [String] = []

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
        paintText()
        for button in buttons { button.view.themeChanged() }
    }

    /// The dead card's strip: plain lines, no buttons.
    func show(lines: [String]) {
        title = nil
        label.stringValue = lines.joined(separator: "\n")
        setButtons([], onChoice: { _ in })
    }

    /// The resume panel: the title over the whole command, and its buttons.
    func show(_ panel: ResumePanel.Model, onChoice: @escaping (ResumePanel.Choice) -> Void) {
        title = panel.title
        label.stringValue = "\(panel.title)\n\(panel.command)"
        paintText()
        setButtons(panel.buttons, onChoice: onChoice)
    }

    /// The button of `choice`, while it shows.
    func button(_ choice: ResumePanel.Choice) -> NSView? {
        buttons.first { $0.choice == choice }?.view
    }

    private func setButtons(_ models: [ResumePanel.Button], onChoice: @escaping (ResumePanel.Choice) -> Void) {
        if buttons.map(\.choice) != models.map(\.choice) {
            for button in buttons { button.view.removeFromSuperview() }
            buttons = models.map { model in
                let view = ChipView()
                view.apply(scale)
                addSubview(view)
                return (model.choice, view)
            }
        }
        for (button, model) in zip(buttons, models) {
            button.view.onClick = { onChoice(model.choice) }
            button.view.setLabel(model.text)
        }
        buttonTexts = models.map(\.text)
    }

    /// The title reads faint, as a chip's label; the command in full colour.
    private func paintText() {
        guard let title, label.stringValue.hasPrefix(title) else { return }
        let text = NSMutableAttributedString(
            string: label.stringValue, attributes: [.font: label.font ?? Theme.mono(9), .foregroundColor: Theme.text]
        )
        text.addAttribute(.foregroundColor, value: Theme.faint, range: NSRange(location: 0, length: (title as NSString).length))
        label.attributedStringValue = text
    }

    func apply(_ scale: CardScale) {
        self.scale = scale
        label.font = Theme.mono(scale.length(ChipMetrics.fontSize))
        paintText()
        layer?.cornerRadius = scale.length(ChipMetrics.cornerRadius)
        layer?.borderWidth = scale.line(1)
        for button in buttons { button.view.apply(scale) }
    }

    /// Lays the strip out along the bottom of `body`, a rect in the card
    /// layer's coordinates: its wrapped text, then its buttons in a row. The
    /// text is measured again only when what it depends on changed.
    func place(along body: CGRect) {
        let inset = scale.length(Self.inset)
        let width = max(0, body.width - 2 * inset)
        let now = Measured(bodySize: body.size, scale: scale, text: label.stringValue, buttons: buttonTexts)
        if now != measured {
            measured = now
            let padX = scale.length(ChipMetrics.padX), padY = scale.length(ChipMetrics.padY)
            let textWidth = max(0, width - 2 * padX)
            let textHeight = ceil(label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            label.frame = NSRect(x: padX, y: padY, width: textWidth, height: textHeight)
            var x = padX
            var rowHeight: CGFloat = 0
            let rowY = padY + textHeight + (buttons.isEmpty ? 0 : padY)
            for button in buttons {
                let size = button.view.intrinsicContentSize
                button.view.frame = NSRect(x: scale.aligned(x), y: scale.aligned(rowY), width: size.width, height: size.height)
                x += size.width + scale.length(Self.buttonGap)
                rowHeight = max(rowHeight, size.height)
            }
            height = min(rowY + rowHeight + padY, body.height)
            frame.size = NSSize(width: width, height: height)
        }
        frame.origin = NSPoint(x: body.minX + inset, y: body.maxY - inset - height)
    }

    /// A reopen strip is one button. On the panel only its buttons take a
    /// press: one elsewhere falls through to the card, which selects it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if onPress != nil { return self }
        return hit is ChipView ? hit : nil
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }
}
