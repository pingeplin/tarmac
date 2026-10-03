import AppKit
import TarmacKit
import WebKit

/// An HTML card's web view. Every wheel it is handed — by the shield, or by
/// AppKit once the card is borrowed — reaches WebKit with its delta in the
/// document's own units, so the document scrolls natively and at the finger's
/// travel in either state. What the delta becomes is `CardWheel`'s.
@MainActor
final class HTMLCardWebView: WKWebView {
    /// Document units per screen point of wheel travel, asked per event.
    var wheelScale: () -> CGFloat = { 1 }

    private var wheel = CardWheel()

    /// A new document starts with no residue.
    func resetWheel() {
        wheel = CardWheel()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: converted(event) ?? event)
    }

    /// `event` with its delta converted, or nil where it passes as it is. A
    /// precise device's delta is the event's point fields and a notched
    /// wheel's its fixed-point line fields; axis 1 is the vertical one.
    /// Nothing else of the copy is touched, so the rebuilt event keeps its
    /// phases, its window and its location.
    private func converted(_ event: NSEvent) -> NSEvent? {
        guard let copy = event.cgEvent?.copy() else { return nil }
        let precise = event.hasPreciseScrollingDeltas
        let (vertical, horizontal): (CGEventField, CGEventField) = precise
            ? (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)
            : (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2)
        let delta = wheel.convert(
            dx: copy.getDoubleValueField(horizontal), dy: copy.getDoubleValueField(vertical),
            precise: precise, scale: wheelScale()
        )
        switch delta {
        case nil:
            return nil
        case .points(let dx, let dy):
            copy.setDoubleValueField(vertical, value: Double(dy))
            copy.setDoubleValueField(horizontal, value: Double(dx))
        case .lines(let dx, let dy):
            copy.setDoubleValueField(vertical, value: dy)
            copy.setDoubleValueField(horizontal, value: dx)
        }
        return NSEvent(cgEvent: copy)
    }
}
