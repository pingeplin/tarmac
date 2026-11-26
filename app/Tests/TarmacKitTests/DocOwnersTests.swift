import XCTest

@testable import TarmacKit

/// The terminal that opened each doc on a board, keyed by the doc's bytes
/// (spec 2611.0034, #551).
final class DocOwnersTests: XCTestCase {
    private let nfc = "/v/caf\u{e9}.md"
    private let nfd = "/v/cafe\u{301}.md"

    func testTwoFormsOfOneNameKeepTheirOwnOwners() {
        var owners = DocOwners()
        owners[nfc] = "term-a"
        owners[nfd] = "term-b"
        XCTAssertEqual(owners[nfc], "term-a")
        XCTAssertEqual(owners[nfd], "term-b")
    }

    func testRemovingOneFormKeepsTheOther() {
        var owners = DocOwners()
        owners[nfc] = "term-a"
        owners[nfd] = "term-b"
        owners[nfd] = nil
        XCTAssertEqual(owners[nfc], "term-a")
        XCTAssertNil(owners[nfd])
    }

    func testAPathWithNoOwnerHasNone() {
        XCTAssertNil(DocOwners()[nfc])
    }
}
