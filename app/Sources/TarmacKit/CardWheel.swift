import CoreGraphics

/// One HTML card's wheel conversion: what to write into a wheel event so that
/// its travel is in the document's own units, or nil to pass the event on
/// unchanged. A precise delta is written to an integer event field, so each
/// axis's residue is kept for the next event (spec 2610.0002).
public struct CardWheel: Equatable, Sendable {
    public enum Delta: Equatable, Sendable {
        /// A precise device: whole document units.
        case points(dx: Int, dy: Int)
        /// A notched wheel: lines of the document.
        case lines(dx: Double, dy: Double)
    }

    private var carryX = 0.0
    private var carryY = 0.0

    public init() {}

    /// `dx` and `dy` are the event's own delta fields, sign and all: points
    /// when `precise`, lines otherwise.
    public mutating func convert(dx: Double, dy: Double, precise: Bool, scale: CGFloat) -> Delta? {
        guard scale.isFinite, scale > 0, scale != 1 else { return nil }
        let scale = Double(scale)
        guard precise else { return .lines(dx: dx * scale, dy: dy * scale) }
        let x = CardZoom.quantizeScrollDelta(dx * scale, carry: carryX)
        let y = CardZoom.quantizeScrollDelta(dy * scale, carry: carryY)
        carryX = x.carry
        carryY = y.carry
        return .points(dx: x.step, dy: y.step)
    }
}
