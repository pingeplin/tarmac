import CoreGraphics

/// Where the toast column sits: against the board area's bottom-right corner,
/// right-aligned, the newest toast lowest. Sizes come from the view, which
/// knows the text metrics.
public enum ToastStackLayout {
    public static let rightInset: CGFloat = 14
    public static let bottomInset: CGFloat = 38
    public static let gap: CGFloat = 8

    /// One frame per size, in the same order (oldest first), in the top-down
    /// coordinates of `area`.
    public static func frames(sizes: [CGSize], in area: CGRect) -> [CGRect] {
        var bottom = area.maxY - bottomInset
        var frames: [CGRect] = []
        for size in sizes.reversed() {
            frames.append(CGRect(
                x: area.maxX - rightInset - size.width, y: bottom - size.height,
                width: size.width, height: size.height
            ))
            bottom -= size.height + gap
        }
        return frames.reversed()
    }
}
