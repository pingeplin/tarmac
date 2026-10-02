import AppKit
import TarmacKit

/// The shield over an HTML card's document. It takes every press and wheel
/// meant for the document, so the card is looked at and not touched: a press
/// only selects the card, and the document sees nothing until a double-click
/// borrows it.
@MainActor
final class CardShieldView: NSView {
    var onBorrow: (() -> Void)?
    /// A wheel over the shield. It only arrives while the card is selected;
    /// over any other card the board pans instead.
    var onScroll: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onBorrow?() }
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}

/// An HTML card's console: what its document logged, one line per entry, over
/// the bottom of the body and at most `maxFraction` of it high.
@MainActor
final class CardConsoleView: NSView {
    static let maxFraction: CGFloat = 0.4

    private static let font = Theme.mono(10)
    private static let lineHeight: CGFloat = 15
    private static let errorColor = NSColor(srgbRed: 0xf2 / 255, green: 0x8b / 255, blue: 0x82 / 255, alpha: 1)
    private static let inset = NSSize(width: 8, height: 4)

    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let hairline = NSView()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.withAlphaComponent(0.94).cgColor

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = Self.inset
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        addSubview(scroll)

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = Theme.lineSoft.cgColor
        addSubview(hairline)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ entries: [CardConsole.Entry]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        paragraph.lineBreakMode = .byCharWrapping
        let lines = NSMutableAttributedString()
        for (index, entry) in entries.enumerated() {
            lines.append(NSAttributedString(
                string: (index == 0 ? "" : "\n") + CardConsole.formatArgs(entry.args),
                attributes: [.font: Self.font, .foregroundColor: Self.color(of: entry.level), .paragraphStyle: paragraph]
            ))
        }
        text.textStorage?.setAttributedString(lines)
    }

    /// The height the lines take at `width`, the insets included. Measured
    /// from the text itself: the text view has no width yet when the panel is
    /// first opened, and would report no height at all.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let lines = text.textStorage else { return 0 }
        let room = NSSize(width: max(0, width - 2 * Self.inset.width), height: .greatestFiniteMagnitude)
        let used = lines.boundingRect(with: room, options: [.usesLineFragmentOrigin])
        return (used.height + 2 * Self.inset.height).rounded(.up)
    }

    override func layout() {
        super.layout()
        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        scroll.frame = bounds
    }

    private static func color(of level: CardConsole.Level) -> NSColor {
        switch level {
        case .warn: return Theme.amber
        case .error: return errorColor
        case .log, .info: return Theme.muted
        }
    }
}
