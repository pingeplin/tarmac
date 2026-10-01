import CoreGraphics

/// Pure card-resize geometry: the frame at grab time, the dragged handle and a
/// WORLD-space drag delta give the new frame, clamped to a minimum size. Edge
/// handles resize one axis, corner handles both. The top/left edges move the
/// origin while the opposite edge stays pinned; the minimum applies per active
/// axis.
public enum CardResize {
    public enum Handle: Equatable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }

    public static let minWidth: CGFloat = 160
    public static let minHeight: CGFloat = 90

    public static func frame(
        from start: CGRect,
        dragging handle: Handle,
        by delta: CGVector,
        minSize: CGSize = CGSize(width: minWidth, height: minHeight)
    ) -> CGRect {
        var x = start.origin.x
        var y = start.origin.y
        var width = start.size.width
        var height = start.size.height

        let movesLeft = handle == .topLeft || handle == .bottomLeft || handle == .left
        let movesTop = handle == .topLeft || handle == .topRight || handle == .top
        let resizesWidth = handle != .top && handle != .bottom
        let resizesHeight = handle != .left && handle != .right

        if resizesWidth {
            if movesLeft {
                let newWidth = max(minSize.width, width - delta.dx)
                x += width - newWidth
                width = newWidth
            } else {
                width = max(minSize.width, width + delta.dx)
            }
        }

        if resizesHeight {
            if movesTop {
                let newHeight = max(minSize.height, height - delta.dy)
                y += height - newHeight
                height = newHeight
            } else {
                height = max(minSize.height, height + delta.dy)
            }
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }
}
