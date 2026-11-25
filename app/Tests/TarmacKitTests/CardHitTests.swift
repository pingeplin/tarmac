import CoreGraphics
import XCTest

@testable import TarmacKit

/// What a point on a card is: the scroll thumb while it can be grabbed, then
/// a resize handle, then the content (spec 2610.0004).
final class CardHitTests: XCTestCase {
    private let thumb = CGRect(x: 378, y: 32, width: 10, height: 67)

    private func hit(
        _ x: CGFloat, _ y: CGFloat, thumb: CGRect?, grabbable: Bool = true, handle: CardResize.Handle? = .right
    ) -> CardHit {
        CardHit.at(CGPoint(x: x, y: y), thumb: thumb, grabbable: grabbable, handle: handle)
    }

    /// "Thumb hit wins over the resize strip".
    func testTheThumbComesAheadOfTheResizeStripWhileItCanBeGrabbed() {
        XCTAssertEqual(hit(386, 40, thumb: thumb), .thumb)
        XCTAssertEqual(hit(386, 40, thumb: thumb, grabbable: false), .handle(.right))
        XCTAssertEqual(hit(386, 40, thumb: thumb, grabbable: false, handle: nil), .content)
        XCTAssertEqual(hit(380, 40, thumb: thumb, handle: nil), .thumb)
    }

    /// "Thumb hit test at its edges".
    /// The minimum edges are inside and the maximum ones outside, as a
    /// handle's zone is.
    func testTheThumbEndsAtItsEdges() {
        XCTAssertEqual(hit(378, 32, thumb: thumb), .thumb)
        XCTAssertEqual(hit(387.9, 98.9, thumb: thumb), .thumb)
        for (x, y) in [(377.9, 40), (388, 40), (380, 31.9), (380, 99)] as [(CGFloat, CGFloat)] {
            XCTAssertEqual(hit(x, y, thumb: thumb), .handle(.right), "\(x), \(y)")
        }
    }

    /// "Thumb hit test at its edges".
    func testWithNoThumbLaidOutThePointIsTheHandlesOrTheContents() {
        XCTAssertEqual(hit(386, 40, thumb: nil), .handle(.right))
        XCTAssertEqual(hit(386, 40, thumb: nil, handle: nil), .content)
    }
}
