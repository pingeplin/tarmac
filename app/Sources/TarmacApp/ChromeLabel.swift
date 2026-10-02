import AppKit

/// A one-line overlay label that is measured and placed by its text, the way
/// a stylesheet places an inline box. A text field's cell pads its text 2 pt on
/// either side, which would put every overlay's text 2 pt off its CSS position
/// and make every box 4 pt too wide.
@MainActor
final class ChromeLabel: NSTextField {
    private static let cellInset: CGFloat = 2

    convenience init(_ text: String = "", size: CGFloat, color: NSColor) {
        self.init(labelWithString: text)
        font = Theme.mono(size)
        textColor = color
        lineBreakMode = .byTruncatingTail
    }

    /// What WebKit makes of `line-height: normal`: the font's ascent, descent
    /// and line gap, each rounded to a whole pixel.
    var lineHeight: CGFloat {
        guard let font else { return 0 }
        return font.ascender.rounded() + (-font.descender).rounded() + font.leading.rounded()
    }

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
