import AppKit
import TarmacKit

/// The restore card (backlog §1.2, #358), after the v3 handoff's `.tm-veil`
/// and `.tm-card`: a veil over the board area and a centred card with the
/// restore's lines, and either its three choices (2611.0015 D8) or the any-key
/// footer. It takes every click over the board area and reports it: a choice's
/// button reports that choice, any other press `decide per card`. It holds the
/// keys while it is up; which key does what is the controller's (`KeyLadder`).
/// The board under it is dimmed by `RootView`.
@MainActor
final class RestoreCardView: KeyHoldingView, FontFollowing, ThemeFollowing {
    var onChoice: ((RestoreCard.Choice.Action) -> Void)?

    private enum Metric {
        static let padX: CGFloat = 26
        static let padY: CGFloat = 22
        static let radius: CGFloat = 12
        static let minWidth: CGFloat = 330
        static let rowGap: CGFloat = 9
        static let glyphGap: CGFloat = 8
        static let footerGap: CGFloat = 16
        static let footerPadTop: CGFloat = 12
        static let choiceGap: CGFloat = 8
        /// The choices are chips, at the size of the card's lines.
        static let choiceZoom: CGFloat = 1.2
    }

    private let card = FlippedColumnView()
    private var rows: [(glyph: ChromeLabel?, text: ChromeLabel)] = []
    private var choices: [(action: RestoreCard.Choice.Action, view: ChipView)] = []
    private let footerRule = NSView()
    private let footer = ChromeLabel(RestoreCard.footer, size: 10, color: Theme.faint)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 8 / 255, green: 10 / 255, blue: 13 / 255, alpha: 0.62).cgColor
        card.wantsLayer = true
        card.layer?.cornerRadius = Metric.radius
        card.layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -24)
        shadow.shadowBlurRadius = 30
        card.shadow = shadow
        addSubview(card)
        footerRule.wantsLayer = true
        card.addSubview(footerRule)
        card.addSubview(footer)
        themeChanged()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Each line is a glyph and its text: an ok glyph in the ok colour, any
    /// other dim, as the v3 card's rows. A line with no glyph is plain words,
    /// whose text starts at the column of the others' text.
    func show(_ restore: RestoreCard) {
        for row in rows {
            row.glyph?.removeFromSuperview()
            row.text.removeFromSuperview()
        }
        rows = restore.lines.map { line in
            (
                line.glyph.map { ChromeLabel($0, size: 11, color: line.ok ? Theme.ok : Theme.faint) },
                ChromeLabel(line.text, size: 11, color: Theme.muted)
            )
        }
        for row in rows {
            row.glyph.map(card.addSubview)
            card.addSubview(row.text)
        }
        for choice in choices { choice.view.removeFromSuperview() }
        let scale = CardScale(zoom: Metric.choiceZoom, backing: window?.backingScaleFactor ?? 2)
        choices = restore.choices.map { choice in
            let view = ChipView()
            view.apply(scale)
            view.setLabel(choice.text)
            view.onClick = { [weak self] in self?.onChoice?(choice.action) }
            card.addSubview(view)
            return (choice.action, view)
        }
        footer.isHidden = !choices.isEmpty
        isHidden = false
        needsLayout = true
    }

    func hide() {
        isHidden = true
    }

    /// The button of `action`, while the card shows its choices.
    func button(_ action: RestoreCard.Choice.Action) -> NSView? {
        choices.first { $0.action == action }?.view
    }

    /// The card, in this view's coordinates: the veil is everything else.
    var cardFrame: CGRect { card.frame }

    func themeChanged() {
        card.layer?.backgroundColor = Theme.bg2.cgColor
        card.layer?.borderColor = Theme.line.cgColor
        footerRule.layer?.backgroundColor = Theme.lineSoft.cgColor
        for choice in choices { choice.view.themeChanged() }
    }

    func fontsChanged() {
        needsLayout = true
    }

    /// A choice's button takes its own press; every other point over the board
    /// area is the card's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) as? ChipView ?? self
    }

    override func mouseDown(with event: NSEvent) {
        onChoice?(.perCard)
    }

    override func layout() {
        super.layout()
        var y = Metric.padY
        let glyphColumn = rows.compactMap { $0.glyph?.textSize.width }.max().map { $0 + Metric.glyphGap } ?? 0
        let choiceSizes = choices.map { $0.view.intrinsicContentSize }
        let choicesWidth = choiceSizes.map(\.width).reduce(0, +) + Metric.choiceGap * CGFloat(max(0, choices.count - 1))
        var width = choices.isEmpty ? footer.textSize.width : choicesWidth
        for (index, row) in rows.enumerated() {
            if index > 0 { y += Metric.rowGap }
            row.glyph?.place(at: CGPoint(x: Metric.padX, y: y))
            let textX = Metric.padX + glyphColumn
            row.text.place(at: CGPoint(x: textX, y: y))
            width = max(width, textX - Metric.padX + row.text.textSize.width)
            y += max(row.glyph?.lineHeight ?? 0, row.text.lineHeight)
        }
        let cardWidth = max(Metric.minWidth, (width + 2 * Metric.padX).rounded(.up))
        y += Metric.footerGap
        footerRule.frame = CGRect(x: Metric.padX, y: y, width: cardWidth - 2 * Metric.padX, height: 1)
        y += Metric.footerPadTop
        if choices.isEmpty {
            footer.place(at: CGPoint(x: Metric.padX, y: y))
            y += footer.lineHeight
        } else {
            var x = Metric.padX
            for (choice, size) in zip(choices, choiceSizes) {
                choice.view.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
                x += size.width + Metric.choiceGap
            }
            y += choiceSizes.map(\.height).max() ?? 0
        }
        y += Metric.padY
        card.frame = CGRect(
            x: ((bounds.width - cardWidth) / 2).rounded(), y: ((bounds.height - y) / 2).rounded(),
            width: cardWidth, height: y.rounded(.up)
        )
    }
}
