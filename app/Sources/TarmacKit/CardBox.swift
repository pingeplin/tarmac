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

    /// The box as it is laid out on screen, in screen points. The border and
    /// the header take their world metrics times the zoom, on whole device
    /// pixels. The body alone is not laid out at the zoom: it keeps its world
    /// size inside a container that scales it, so a terminal's grid — measured
    /// from that size — never changes with the zoom.
    public struct Screen: Equatable, Sendable {
        public var border: CGFloat
        public var cornerRadius: CGFloat
        /// The area inside the border, in the card's coordinates.
        public var content: CGRect
        /// The header, in the content area's coordinates.
        public var header: CGRect
        /// The body's container, in the content area's coordinates: `bodySize`
        /// times the zoom. The border and the header are whole device pixels,
        /// so the container can overhang the room under the header — most
        /// where the border is held at one pixel — or fall short of it; the
        /// content area clips the one and shows through the other.
        public var body: CGRect
        /// The size the body is laid out at inside its container.
        public var bodySize: CGSize

        /// The part of the body's container the content area shows. A border
        /// held at one device pixel leaves the body less room than its
        /// container takes.
        public var shownBody: CGRect {
            CGRect(
                x: 0, y: body.minY,
                width: min(body.width, content.width), height: min(body.height, content.height - body.minY)
            )
        }
    }

    /// `cardSize` is the card's size on screen and `worldSize` its world size.
    public static func screen(cardSize: CGSize, worldSize: CGSize, scale: CardScale) -> Screen {
        let border = scale.line(borderWidth)
        let content = CGRect(
            x: border,
            y: border,
            width: max(0, cardSize.width - 2 * border),
            height: max(0, cardSize.height - 2 * border)
        )
        let header = CGRect(x: 0, y: 0, width: content.width, height: min(scale.snapped(headerHeight), content.height))
        let bodySize = body(of: worldSize).size
        return Screen(
            border: border,
            cornerRadius: scale.length(cornerRadius),
            content: content,
            header: header,
            body: CGRect(
                x: 0, y: header.height, width: scale.length(bodySize.width), height: scale.length(bodySize.height)
            ),
            bodySize: bodySize
        )
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
