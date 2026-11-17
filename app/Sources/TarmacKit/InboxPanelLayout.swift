import CoreGraphics

/// The inbox panel's strip in the board area (spec 2611.0013): flush right,
/// full height, never docked. The board keeps its frame under it; the pills,
/// the minimap and the toasts keep to what it leaves uncovered.
public enum InboxPanelLayout {
    /// The cap at the standard Interface size; the app passes what the size
    /// in effect makes of it as `maxWidth`.
    public static let maxWidth: CGFloat = 360

    public static func width(_ area: CGRect, maxWidth: CGFloat) -> CGFloat {
        min(maxWidth, area.width / 3).rounded(.down)
    }

    public static func panelRect(_ area: CGRect, maxWidth: CGFloat) -> CGRect {
        let width = width(area, maxWidth: maxWidth)
        return CGRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
    }

    public static func uncovered(_ area: CGRect, open: Bool, maxWidth: CGFloat) -> CGRect {
        guard open else { return area }
        var rest = area
        rest.size.width -= width(area, maxWidth: maxWidth)
        return rest
    }
}
