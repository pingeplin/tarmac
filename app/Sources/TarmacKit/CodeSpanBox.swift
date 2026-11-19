import CoreGraphics

/// The box behind a code span in wrapped text (spec 2611.0018 D13). It has the
/// look of the inbox row's box (`InlineTextLabel`): the height of a one-line
/// text of the base face, the text's baseline where such a text has it, and
/// the same padding on each side.
public enum CodeSpanBox {
    /// A one-line text of the base face: its height, and its baseline from its top.
    public struct Face: Equatable, Sendable {
        public let baseline: CGFloat
        public let lineHeight: CGFloat

        public init(baseline: CGFloat, lineHeight: CGFloat) {
            self.baseline = baseline
            self.lineHeight = lineHeight
        }
    }

    /// The room between the box's side and the span's text.
    public static let padding: CGFloat = 3
    /// The room the text makes for the padding: a kern on the character
    /// before the span, and one on the span's last character, which is in the
    /// glyphs' rect. So the box starts where the character before it ends and
    /// ends where the next one starts, as in the row.
    public static let kern = padding

    /// `glyphs` is the rect of the span's glyphs on one line and `baseline`
    /// that line's, in the same coordinates. The line's own height plays no
    /// part: line spacing and taller glyphs change it, and not the box.
    public static func rect(glyphs: CGRect, baseline: CGFloat, face: Face) -> CGRect {
        CGRect(
            x: glyphs.minX - padding, y: baseline - face.baseline, width: glyphs.width + padding,
            height: face.lineHeight
        )
    }
}
