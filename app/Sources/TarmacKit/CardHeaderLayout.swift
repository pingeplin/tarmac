import CoreGraphics

/// The horizontal layout of a card header: fixed-width items on the left, the
/// label, a spacer, then fixed-width items packed against the right edge —
/// every neighbour 6 apart, 10 of padding at each side. The label is the only
/// item that gives way: it takes what is left and truncates. The header is
/// laid out at its size on screen, so the gap and the padding take a `scale`.
public enum CardHeaderLayout {
    public static let sidePadding: CGFloat = 10
    public static let gap: CGFloat = 6

    public struct Span: Equatable, Sendable {
        public var x: CGFloat
        public var width: CGFloat

        public init(x: CGFloat, width: CGFloat) {
            self.x = x
            self.width = width
        }
    }

    /// What a text field puts between its edge and its text, on each side. It
    /// is the same at every font size, so it is the one part of a field's
    /// measured width that does not follow the zoom.
    public static let textPadding: CGFloat = 2

    /// How far a text field hangs over each side of the room it takes in the
    /// row: the part of its padding the zoom did not scale. Negative above
    /// 100 %, where the room is the wider of the two.
    public static func textOverhang(scale: CGFloat) -> CGFloat {
        textPadding * (1 - scale)
    }

    /// The room a text field takes in the row: its text's own width, plus the
    /// padding scaled like every other metric.
    public static func textItemWidth(text: CGFloat, scale: CGFloat) -> CGFloat {
        text + 2 * textPadding * scale
    }

    /// The width of the text field itself: its text and the padding, rounded
    /// up, since a field a fraction short of its text truncates it.
    public static func textFieldWidth(text: CGFloat) -> CGFloat {
        (text + 2 * textPadding).rounded(.up)
    }

    public struct Frames: Equatable, Sendable {
        public var leading: [Span]
        public var label: Span
        public var trailing: [Span]
    }

    /// `leading` and `trailing` are the widths of the items present, in reading
    /// order; `label` is the label's natural width. Widths are as measured on
    /// screen, already at `scale`.
    public static func frames(
        width: CGFloat, leading: [CGFloat], label: CGFloat, trailing: [CGFloat], scale: CGFloat = 1
    ) -> Frames {
        let sidePadding = Self.sidePadding * scale
        let gap = Self.gap * scale
        var x = sidePadding
        let leadingSpans = leading.map { itemWidth in
            defer { x += itemWidth + gap }
            return Span(x: x, width: itemWidth)
        }
        let labelX = x

        var right = width - sidePadding
        let trailingSpans = Array(trailing.reversed().map { itemWidth in
            defer { right -= itemWidth + gap }
            return Span(x: right - itemWidth, width: itemWidth)
        }.reversed())

        // The spacer is an item too, so it costs a gap of its own.
        let room = right - gap - labelX
        return Frames(
            leading: leadingSpans,
            label: Span(x: labelX, width: min(label, max(0, room))),
            trailing: trailingSpans
        )
    }
}
