import CoreGraphics

/// Where a wheel or pinch over the board goes, and how far a pinch zooms.
public enum BoardWheel {
    public enum Route: Equatable, Sendable {
        /// The card's own content scrolls (terminal scrollback, doc scroll).
        case card
        case pan
        case zoom
    }

    /// A pinch always zooms the board. A plain wheel scrolls a card only when
    /// it is over the BODY of the selected card; anywhere else — another card,
    /// the selected card's header, the bare board — it pans.
    public static func route<ID: Equatable>(pinch: Bool, over card: ID?, inBody: Bool, selected: ID?) -> Route {
        if pinch { return .zoom }
        if let card, card == selected, inBody { return .card }
        return .pan
    }

    /// The zoom multiplier for a wheel turned with control held. `deltaY`
    /// follows the web convention: positive scrolls down, which zooms out.
    public static func zoomFactor(deltaY: CGFloat) -> CGFloat {
        exp(-deltaY * 0.01)
    }

    /// The zoom multiplier for one trackpad magnify step.
    public static func zoomFactor(magnification: CGFloat) -> CGFloat {
        1 + magnification
    }

    /// Screen points per line of a notched wheel, which reports lines.
    public static let lineTravel: CGFloat = 10

    /// How far a wheel event moves the content, in screen points, from
    /// AppKit's scrolling delta.
    public static func travel(scrollingDelta: CGVector, precise: Bool) -> CGVector {
        let scale = precise ? 1 : lineTravel
        return CGVector(dx: scrollingDelta.dx * scale, dy: scrollingDelta.dy * scale)
    }

    /// The zoom multiplier for a wheel turned with control held. AppKit's
    /// travel has the opposite sign to the web's `deltaY`.
    public static func zoomFactor(travel: CGVector) -> CGFloat {
        zoomFactor(deltaY: -travel.dy)
    }
}
