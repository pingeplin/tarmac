import CoreGraphics

/// The inbox panel's strip in the board area (spec 2611.0013): flush right,
/// full height, never docked. The board keeps its frame under it; the pills,
/// the minimap and the toasts keep to what it leaves uncovered.
public enum InboxPanelLayout {
    public static let maxWidth: CGFloat = 360

    public static func width(_ area: CGRect) -> CGFloat {
        min(maxWidth, area.width / 3).rounded(.down)
    }

    public static func panelRect(_ area: CGRect) -> CGRect {
        let width = width(area)
        return CGRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
    }

    public static func uncovered(_ area: CGRect, open: Bool) -> CGRect {
        guard open else { return area }
        return CGRect(x: area.minX, y: area.minY, width: area.width - width(area), height: area.height)
    }
}
