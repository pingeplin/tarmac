import XCTest

@testable import TarmacKit

/// The cull polarity an HTML card's scheduler gate reads (spec 2609.0002).
final class CardCullTests: XCTestCase {
    /// "Cull message is state not toggle".
    /// A state, not a toggle: a repeat of the same input gives the same answer.
    func testThePolarityDependsOnlyOnItsArgument() {
        XCTAssertTrue(CardCull.isCulled(visible: false))
        XCTAssertTrue(CardCull.isCulled(visible: false))
        XCTAssertFalse(CardCull.isCulled(visible: true))
        XCTAssertTrue(CardCull.isCulled(visible: false))
    }
}
