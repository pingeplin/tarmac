import CoreGraphics

/// The horizontal layout of a card header: fixed-width items on the left, the
/// label, a spacer, then fixed-width items packed against the right edge —
/// every neighbour 6 apart, 10 of padding at each side. The label is the only
/// item that gives way: it takes what is left and truncates.
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

    public struct Frames: Equatable, Sendable {
        public var leading: [Span]
        public var label: Span
        public var trailing: [Span]
    }

    /// `leading` and `trailing` are the widths of the items present, in reading
    /// order; `label` is the label's natural width.
    public static func frames(width: CGFloat, leading: [CGFloat], label: CGFloat, trailing: [CGFloat]) -> Frames {
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
