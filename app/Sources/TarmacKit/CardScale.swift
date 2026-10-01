import CoreGraphics

/// The scale a card's chrome is laid out at: the board's zoom, and the density
/// of the display its edges are put on. Chrome is laid out at its size on
/// screen — every metric times the zoom — rather than drawn at world size and
/// scaled down as a picture, which lands its edges between device pixels and
/// softens them.
public struct CardScale: Equatable, Sendable {
    public var zoom: CGFloat
    /// Device pixels per screen point.
    public var backing: CGFloat

    public init(zoom: CGFloat, backing: CGFloat) {
        self.zoom = zoom
        self.backing = backing
    }

    /// A world length on screen.
    public func length(_ world: CGFloat) -> CGFloat {
        world * zoom
    }

    /// A screen coordinate moved to the nearest whole device pixel.
    public func aligned(_ screen: CGFloat) -> CGFloat {
        (screen * backing).rounded() / backing
    }

    /// A world length on screen, in whole device pixels.
    public func snapped(_ world: CGFloat) -> CGFloat {
        aligned(length(world))
    }

    /// A line's width on screen, as a browser snaps a border: whole device
    /// pixels, rounded down, and never fewer than one, so a line stays visible
    /// however far out the board is zoomed.
    public func line(_ world: CGFloat) -> CGFloat {
        // To a 64th of a pixel first, as a browser's layout unit does: a zoom a
        // rounding error below a whole pixel must not round down past it.
        let pixels = (world * zoom * backing * 64).rounded() / 64
        return max(1, pixels.rounded(.down)) / backing
    }
}
