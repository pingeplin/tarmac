import AppKit

extension NSFont {
    /// What WebKit makes of `line-height: normal`: the font's ascent, descent
    /// and line gap, each rounded to a whole pixel.
    var normalLineHeight: CGFloat {
        ascender.rounded() + (-descender).rounded() + leading.rounded()
    }
}

/// A one-line overlay label that is measured and placed by its text, the way
/// a stylesheet places an inline box. A text field's cell pads its text 2 pt on
/// either side, which would put every overlay's text 2 pt off its CSS position
/// and make every box 4 pt too wide.
@MainActor
final class ChromeLabel: NSTextField, FontFollowing, ThemeFollowing {
    private static let cellInset: CGFloat = 2

    private var size: CGFloat = NSFont.systemFontSize
    private var color: () -> NSColor = { .labelColor }

    convenience init(_ text: String = "", size: CGFloat, color: @escaping @autoclosure () -> NSColor) {
        self.init(labelWithString: text)
        self.size = size
        font = Theme.mono(size)
        self.color = color
        textColor = color()
        lineBreakMode = .byTruncatingTail
    }

    /// The colour is kept as the token it is read from, not as its value, so
    /// that it can be read again when the theme changes.
    func setColor(_ color: @escaping @autoclosure () -> NSColor) {
        self.color = color
        textColor = color()
    }

    func themeChanged() {
        textColor = color()
    }

    func fontsChanged() {
        font = Theme.mono(size)
        superview?.needsLayout = true
    }

    var lineHeight: CGFloat { font?.normalLineHeight ?? 0 }

    /// The untruncated text's line box: its advance width, not rounded, by
    /// `lineHeight`.
    var textSize: NSSize {
        NSSize(width: attributedStringValue.size().width, height: lineHeight)
    }

    /// Puts the line box's top-left corner at `origin`, on a whole point; a
    /// `width` narrower than the text truncates it.
    func place(at origin: CGPoint, width: CGFloat? = nil) {
        frame = NSRect(
            x: origin.x.rounded() - Self.cellInset,
            y: origin.y.rounded(),
            width: (width ?? textSize.width).rounded(.up) + 2 * Self.cellInset,
            height: fittedSize.height
        )
    }
}
