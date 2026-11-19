import CoreGraphics

/// The box behind a code span in wrapped text (spec 2611.0018 D13): where it
/// is, from the rect of the span's glyphs on one line.
public enum CodeSpanBox {
    /// How far the box reaches left of the span's first glyph.
    public static let inset: CGFloat = 3.5
    /// What the box adds to the glyphs' width.
    private static let extraWidth: CGFloat = 2
    /// The room the text makes for the box, before the span and after it.
    public static let kern = 2 * inset - extraWidth

    /// TextKit puts the paragraph's line spacing below every line but the
    /// last line of the text, so only there is it not in the glyphs' rect.
    public static func rect(glyphs: CGRect, lineSpacing: CGFloat, lastLineOfText: Bool) -> CGRect {
        CGRect(
            x: glyphs.minX - inset, y: glyphs.minY, width: glyphs.width + extraWidth,
            height: glyphs.height - (lastLineOfText ? 0 : lineSpacing)
        )
    }
}
