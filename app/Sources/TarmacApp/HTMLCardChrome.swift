import AppKit
import TarmacKit

/// The shield over an HTML card's document. It takes every press meant for
/// the document, so the card is looked at and not touched: a press only
/// selects the card, until a double-click borrows it. A wheel is the one
/// thing it hands on: reading is not the touch it is there to stop.
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
final class CardConsoleView: NSView, FontFollowing {
    static let maxFraction: CGFloat = 0.4

    private static var font: NSFont { Theme.mono(10) }
    private static let lineHeight: CGFloat = 15
    private static let errorColor = NSColor(srgbRed: 0xf2 / 255, green: 0x8b / 255, blue: 0x82 / 255, alpha: 1)
    private static let inset = NSSize(width: 8, height: 4)

    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let hairline = NSView()
    private var measured = LastResult<NSSize, CGFloat>()

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
        measured.forget()
    }

    func fontsChanged() {
        guard let storage = text.textStorage else { return }
        storage.addAttribute(.font, value: Self.font, range: NSRange(location: 0, length: storage.length))
        measured.forget()
        superview?.needsLayout = true
    }

    /// The height the lines take at `width`, the insets included, and no more
    /// than `limit`. A full console is half a megabyte of text and typesetting
    /// all of it takes a tenth of a second: so only as much as fills `limit`
    /// is typeset, and once per text, width and limit, not once per layout.
    func height(forWidth width: CGFloat, atMost limit: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        measured.value(for: NSSize(width: width, height: limit)) { room in
            guard let container = text.textContainer, let layoutManager = text.layoutManager else { return 0 }
            // The text wraps at the text view's width, and the text view has
            // none until the panel is first laid out.
            scroll.setFrameSize(NSSize(width: room.width, height: scroll.frame.height))
            layoutManager.ensureLayout(forBoundingRect: NSRect(origin: .zero, size: room), in: container)
            let lines = layoutManager.usedRect(for: container).height + 2 * Self.inset.height
            return min(room.height, lines.rounded(.up))
        }
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
