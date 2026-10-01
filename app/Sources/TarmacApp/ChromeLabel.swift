import AppKit

/// A one-line overlay label that is measured and placed by its text, the way
/// a stylesheet places an inline box. A text field's cell pads its text 2 pt on
/// either side, which would put every overlay's text 2 pt off its CSS position
/// and make every box 4 pt too wide.
@MainActor
final class ChromeLabel: NSTextField {
    private static let cellInset: CGFloat = 2

    convenience init(_ text: String = "", size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        self.init(labelWithString: text)
        font = Theme.mono(size, weight: weight)
        textColor = color
        lineBreakMode = .byTruncatingTail
    }

    /// The untruncated text's size.
    var textSize: NSSize {
        let fitted = fittedSize
        return NSSize(width: max(0, fitted.width - 2 * Self.cellInset), height: fitted.height)
    }

    /// Puts the text's top-left corner at `origin`; a `width` narrower than the
    /// text truncates it.
    func place(at origin: CGPoint, width: CGFloat? = nil) {
        let size = textSize
        frame = NSRect(
            x: origin.x - Self.cellInset, y: origin.y,
            width: (width ?? size.width) + 2 * Self.cellInset, height: size.height
        )
    }
}
