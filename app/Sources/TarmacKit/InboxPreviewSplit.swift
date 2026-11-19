import CoreGraphics

/// The split between the inbox list and its preview pane (spec 2611.0018 D7).
/// A height the user sets is "wanted", in design points; what the panel's room
/// lets the pane have is "shown", in screen points. Only the wanted one is
/// saved, so a small window never overwrites it.
public enum InboxPreviewSplit {
    public static let standard: Double = 236
    public static let minimum: Double = 72
    /// The highest height `AppPrefs` reads back.
    public static let maximum: Double = 2000
    /// About two rows of the list.
    public static let listMinimum: Double = 126
    public static let step: Double = 24

    /// `room` is what the panel has between its header and its footer, less
    /// the grip, in screen points; `scale` is the Interface size's factor.
    public static func shown(wanted: Double?, room: CGFloat, scale: CGFloat) -> CGFloat {
        let low = minimum * scale
        let high = max(low, room - listMinimum * scale)
        return min(max((wanted ?? standard) * scale, low), high).rounded()
    }

    public static func stepped(wanted: Double?, steps: Int, room: CGFloat, scale: CGFloat) -> Double? {
        moved(wanted, by: Double(steps) * step, room: room, scale: scale)
    }

    /// A positive `delta` (screen points) is the grip moved up: the pane grows.
    public static func dragged(wanted: Double?, by delta: CGFloat, room: CGFloat, scale: CGFloat) -> Double? {
        moved(wanted, by: delta / scale, room: room, scale: scale)
    }

    /// From the shown height, so a key works at once in a window too small
    /// for the wanted one. A move that shows no change keeps `wanted`: a plain
    /// click on the grip must not overwrite a saved height.
    private static func moved(_ wanted: Double?, by delta: Double, room: CGFloat, scale: CGFloat) -> Double? {
        let high = min(maximum, max(minimum, room / scale - listMinimum))
        let clamp = { (height: Double) in min(max(height, minimum), high) }
        let start = clamp(wanted ?? standard)
        let end = clamp(start + delta)
        return end == start ? wanted : end
    }
}
