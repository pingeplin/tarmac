import AppKit
import TarmacKit

/// One inbox item: its kind tag, title and age; the quote of a report; its
/// place. A read row's text goes faint and its tag keeps the kind's colour on
/// its border; nothing is dimmed by transparency.
@MainActor
final class InboxRowView: OverlayRowView {
    private enum Metric {
        static let padX: CGFloat = 14
        static let padY: CGFloat = 8
        static let lineGap: CGFloat = 3
        static let gap: CGFloat = 8
    }

    @MainActor
    private enum Font {
        static var title: NSFont { Theme.mono(11) }
        static var place: NSFont { Theme.mono(10) }
        static var age: NSFont { Theme.mono(10) }
    }

    private let kindTag = ChipView()
    private let title = OverlayLabel()
    private let age = OverlayLabel()
    private let quote = InlineTextLabel(style: quoteStyle(read: false, selected: false))
    private let place = OverlayLabel()

    override init() {
        super.init()
        for label in [title, place] { label.lineBreakMode = .byTruncatingTail }
        for view in [kindTag, title, age, quote, place] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A read row's text goes faint, marks too; a selected row's code box is `bg2`.
    private static func quoteStyle(read: Bool, selected: Bool) -> InlineTextLabel.Style {
        InlineTextLabel.Style(
            design: 11, color: read ? Theme.faint : Theme.muted, boxFill: selected ? Theme.bg2 : Theme.bg1,
            boxBorder: Theme.line
        )
    }

    func configure(_ row: InboxRow, selected: Bool) {
        self.selected = selected
        kindTag.setTone(.signal(row.kind.signal, dimmed: row.read))
        kindTag.setLabel(InboxCopy.tag(row.kind))
        title.attributedStringValue = NSAttributedString(
            string: row.title, attributes: [.font: Font.title, .foregroundColor: row.read ? Theme.faint : Theme.text]
        )
        age.attributedStringValue = NSAttributedString(
            string: row.age, attributes: [.font: Font.age, .foregroundColor: Theme.faint]
        )
        quote.style = Self.quoteStyle(read: row.read, selected: selected)
        quote.text = row.quote ?? InlineText([])
        quote.isHidden = row.quote == nil
        place.attributedStringValue = NSAttributedString(
            string: row.place, attributes: [.font: Font.place, .foregroundColor: Theme.faint]
        )
        toolTip = row.toolTip
        needsLayout = true
    }

    func height() -> CGFloat {
        let first = max(kindTag.intrinsicContentSize.height, title.fittedSize.height)
        let lines = [first, quote.isHidden ? nil : quote.fittedSize.height, place.fittedSize.height].compactMap { $0 }
        return Metric.padY * 2 + lines.reduce(0, +) + Metric.lineGap * CGFloat(lines.count - 1)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        kindTag.apply(CardScale(zoom: 1, backing: window?.backingScaleFactor ?? 2))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let tagSize = kindTag.intrinsicContentSize
        let titleSize = title.fittedSize
        let ageSize = age.fittedSize
        let first = max(tagSize.height, titleSize.height)
        kindTag.frame = NSRect(
            x: Metric.padX, y: first.centered(tagSize.height, top: Metric.padY),
            width: tagSize.width, height: tagSize.height
        )
        age.frame = NSRect(
            x: width - Metric.padX - ageSize.width, y: first.centered(ageSize.height, top: Metric.padY),
            width: ageSize.width, height: ageSize.height
        )
        let titleX = kindTag.frame.maxX + Metric.gap
        title.frame = NSRect(
            x: titleX, y: first.centered(titleSize.height, top: Metric.padY),
            width: max(0, min(titleSize.width, age.frame.minX - Metric.gap - titleX)), height: titleSize.height
        )
        var y = Metric.padY + first + Metric.lineGap
        let lines: [(NSView, NSSize)] = [(quote, quote.fittedSize), (place, place.fittedSize)]
        for (label, size) in lines where !label.isHidden {
            label.frame = NSRect(
                x: Metric.padX, y: y, width: min(size.width, width - Metric.padX * 2), height: size.height
            )
            y += size.height + Metric.lineGap
        }
    }
}
