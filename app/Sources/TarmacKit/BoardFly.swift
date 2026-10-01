/// A fly: the board's viewport eased from one place to another over a fixed
/// time. The caller owns the clock and asks where the viewport is at a given
/// elapsed time, so an interrupted fly simply stops being asked.
public struct BoardFly: Equatable, Sendable {
    public static let durationMs: Double = 300

    public let from: BoardViewport
    public let to: BoardViewport

    public init(from: BoardViewport, to: BoardViewport) {
        self.from = from
        self.to = to
    }

    public static func easeInOutQuad(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) / 2
    }

    public func viewport(atElapsedMs elapsedMs: Double) -> BoardViewport {
        if isFinished(atElapsedMs: elapsedMs) { return to }
        let k = Self.easeInOutQuad(max(0, elapsedMs / Self.durationMs))
        return BoardViewport(
            zoom: from.zoom + (to.zoom - from.zoom) * k,
            cx: from.cx + (to.cx - from.cx) * k,
            cy: from.cy + (to.cy - from.cy) * k
        )
    }

    public func isFinished(atElapsedMs elapsedMs: Double) -> Bool {
        elapsedMs >= Self.durationMs
    }
}
