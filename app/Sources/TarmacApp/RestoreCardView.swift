import AppKit
import TarmacKit

/// The restore card (backlog §1.2, #358), after the v3 handoff's `.tm-veil`
/// and `.tm-card`: a veil over the board area and a centred card with the
/// restore's lines and the any-key footer. It takes every click over the board
/// area and reports it, and holds the keys while it is up; which key does what
/// is the controller's (`KeyLadder`). The board under it is dimmed by
/// `RootView`.
@MainActor
final class RestoreCardView: KeyHoldingView, FontFollowing, ThemeFollowing {
    var onDismiss: (() -> Void)?

    private enum Metric {
        static let padX: CGFloat = 26
        static let padY: CGFloat = 22
        static let radius: CGFloat = 12
        static let minWidth: CGFloat = 330
        static let rowGap: CGFloat = 9
        static let glyphGap: CGFloat = 8
        static let footerGap: CGFloat = 16
        static let footerPadTop: CGFloat = 12
    }

    private let card = FlippedColumnView()
    private var rows: [(glyph: ChromeLabel, text: ChromeLabel)] = []
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
    /// other dim, as the v3 card's rows.
    func show(_ restore: RestoreCard) {
        for row in rows {
            row.glyph.removeFromSuperview()
            row.text.removeFromSuperview()
        }
        rows = restore.lines.map { line in
            (
                ChromeLabel(line.glyph, size: 11, color: line.ok ? Theme.ok : Theme.faint),
                ChromeLabel(line.text, size: 11, color: Theme.muted)
            )
        }
        for row in rows {
            card.addSubview(row.glyph)
            card.addSubview(row.text)
        }
        isHidden = false
        needsLayout = true
    }

    func hide() {
        isHidden = true
    }

    func themeChanged() {
        card.layer?.backgroundColor = Theme.bg2.cgColor
        card.layer?.borderColor = Theme.line.cgColor
        footerRule.layer?.backgroundColor = Theme.lineSoft.cgColor
    }

    func fontsChanged() {
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override func layout() {
        super.layout()
        var y = Metric.padY
        var width = footer.textSize.width
        for (index, row) in rows.enumerated() {
            if index > 0 { y += Metric.rowGap }
            row.glyph.place(at: CGPoint(x: Metric.padX, y: y))
            let textX = Metric.padX + row.glyph.textSize.width + Metric.glyphGap
            row.text.place(at: CGPoint(x: textX, y: y))
            width = max(width, textX - Metric.padX + row.text.textSize.width)
            y += max(row.glyph.lineHeight, row.text.lineHeight)
        }
        let cardWidth = max(Metric.minWidth, (width + 2 * Metric.padX).rounded(.up))
        y += Metric.footerGap
        footerRule.frame = CGRect(x: Metric.padX, y: y, width: cardWidth - 2 * Metric.padX, height: 1)
        y += Metric.footerPadTop
        footer.place(at: CGPoint(x: Metric.padX, y: y))
        y += footer.lineHeight + Metric.padY
        card.frame = CGRect(
            x: ((bounds.width - cardWidth) / 2).rounded(), y: ((bounds.height - y) / 2).rounded(),
            width: cardWidth, height: y.rounded(.up)
        )
    }
}
