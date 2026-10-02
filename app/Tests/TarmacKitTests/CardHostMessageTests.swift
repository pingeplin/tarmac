import XCTest
@testable import TarmacKit

/// The host → shim messages of an HTML card (`card_shim.js` message listener)
/// and the cull polarity that feeds one of them (spec 2609.0002 S1–S2).
final class CardHostMessageTests: XCTestCase {
    func testZoomCarriesTheFactorAsZ() {
        XCTAssertEqual(CardHostMessage.zoom(3).json, #"{"tarmac":"zoom","z":3}"#)
        XCTAssertEqual(CardHostMessage.zoom(1.5).json, #"{"tarmac":"zoom","z":1.5}"#)
    }

    /// The shim acts only on a real boolean, so the payload must not be 0/1.
    func testCullCarriesARealBoolean() {
        XCTAssertEqual(CardHostMessage.cull(true).json, #"{"tarmac":"cull","culled":true}"#)
        XCTAssertEqual(CardHostMessage.cull(false).json, #"{"tarmac":"cull","culled":false}"#)
    }

    func testScrollCarriesWholePixelsPerAxis() {
        XCTAssertEqual(CardHostMessage.scroll(dx: 35, dy: -2).json, #"{"tarmac":"scroll","dx":35,"dy":-2}"#)
    }

    // MARK: - cull polarity (2609.0002 S1, S2)

    func testS1ACulledCardIsOneThatIsNotVisible() {
        XCTAssertEqual(CardHostMessage.cull(CardCull.isCulled(visible: false)), .cull(true))
        XCTAssertEqual(CardHostMessage.cull(CardCull.isCulled(visible: true)), .cull(false))
    }

    /// A state, not a toggle: a repeat of the same input gives the same answer.
    func testS2ThePolarityDependsOnlyOnItsArgument() {
        XCTAssertTrue(CardCull.isCulled(visible: false))
        XCTAssertTrue(CardCull.isCulled(visible: false))
        XCTAssertFalse(CardCull.isCulled(visible: true))
        XCTAssertTrue(CardCull.isCulled(visible: false))
    }
}
