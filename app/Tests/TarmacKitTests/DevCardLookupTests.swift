import XCTest

@testable import TarmacKit

/// The card a QA-driver verb names by its wire id: the one with the same
/// bytes (spec 2611.0034, #551).
final class DevCardLookupTests: XCTestCase {
    private let nfc = "/v/caf\u{e9}.md"
    private let nfd = "/v/cafe\u{301}.md"

    /// Bytes, not `String ==`: that would call the two forms one id.
    private func found(_ id: String, in ids: [String]) -> [UInt8]? {
        DevCardLookup.card(id, in: ids, wireID: { $0 }).map { Array($0.utf8) }
    }

    func testEachFormFindsItsOwnCardInEitherOrder() {
        for ids in [[nfc, nfd], [nfd, nfc]] {
            XCTAssertEqual(found(nfc, in: ids), Array(nfc.utf8))
            XCTAssertEqual(found(nfd, in: ids), Array(nfd.utf8))
        }
    }

    func testAnIdNoCardHasFindsNone() {
        XCTAssertNil(found("term-1", in: [nfc, nfd]))
    }
}
