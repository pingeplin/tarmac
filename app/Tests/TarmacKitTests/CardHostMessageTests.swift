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

    func test2610_0004S10ScrollToCarriesThePositionAsY() {
        XCTAssertEqual(CardHostMessage.scrollTo(300).json, #"{"tarmac":"scrollTo","y":300}"#)
        XCTAssertEqual(CardHostMessage.scrollTo(132.5).json, #"{"tarmac":"scrollTo","y":132.5}"#)
    }

    /// 2610.0002 S24, as 2610.0004 leaves it: the wheel is the web view's,
    /// not a message, and a held thumb says where the root goes. A fourth
    /// case does not compile here.
    func test2610_0004S10TheHostSaysAZoomACullOrAScrollTo() {
        func names(_ message: CardHostMessage) -> String {
            switch message {
            case .zoom: "zoom"
            case .cull: "cull"
            case .scrollTo: "scrollTo"
            }
        }
        XCTAssertEqual(names(.zoom(3)), "zoom")
        XCTAssertEqual(names(.cull(true)), "cull")
        XCTAssertEqual(names(.scrollTo(0)), "scrollTo")
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
