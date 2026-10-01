import CoreGraphics

/// A card's box model in world units: a 1-wide border, a 30-high header and
/// the body below it, both laid out INSIDE the border. The body is therefore
/// the card minus the header and minus both borders — which is what a
/// terminal's grid is measured from.
public enum CardBox {
    public static let headerHeight: CGFloat = 30
    public static let borderWidth: CGFloat = 1
    public static let cornerRadius: CGFloat = 10

    /// The area inside the border, in the card's own coordinates.
    public static func content(of size: CGSize) -> CGRect {
        CGRect(
            x: borderWidth,
            y: borderWidth,
            width: max(0, size.width - 2 * borderWidth),
            height: max(0, size.height - 2 * borderWidth)
        )
    }

    /// The header, in the content area's coordinates.
    public static func header(of size: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: content(of: size).width, height: headerHeight)
    }

    /// The body, in the content area's coordinates.
    public static func body(of size: CGSize) -> CGRect {
        let content = content(of: size)
        return CGRect(x: 0, y: headerHeight, width: content.width, height: max(0, content.height - headerHeight))
    }

    /// The card whose body is `body` across: the inverse of `body(of:)`.
    public static func cardSize(ofBody body: CGSize) -> CGSize {
        CGSize(width: body.width + 2 * borderWidth, height: body.height + headerHeight + 2 * borderWidth)
    }

    /// The box an HTML card's document is laid out in: the card minus its
    /// header. The borders are not taken off, so it overhangs the body by
    /// them and is clipped there.
    public static func documentBox(of size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(0, size.height - headerHeight))
    }
}
