import XCTest

@testable import TarmacKit

/// A doc path is its UTF-8 bytes, as the daemon's registry keys it (spec 2611.0034).
final class DocPathTests: XCTestCase {
    private let nfc = "/v/\u{e9}/a.md"
    private let nfd = "/v/e\u{301}/a.md"

    func testTwoFormsOfOneNameAreTwoDocPaths() {
        XCTAssertNotEqual(DocPath(nfc), DocPath(nfd))
        XCTAssertEqual(Set([DocPath(nfc), DocPath(nfd)]).count, 2)
    }

    func testSameBytesAreOneDocPath() {
        let built = String(decoding: Array(nfd.utf8), as: UTF8.self)
        var literal = Hasher()
        DocPath(nfd).hash(into: &literal)
        var decoded = Hasher()
        DocPath(built).hash(into: &decoded)
        XCTAssertEqual(DocPath(nfd), DocPath(built))
        XCTAssertEqual(literal.finalize(), decoded.finalize())
    }

    func testDocPathKeepsItsString() {
        XCTAssertEqual(Array(DocPath(nfd).string.utf8), Array(nfd.utf8))
    }

    func testTwoFormsThatUnicodeCallsOneAreTwoDocPaths() {
        XCTAssertNotEqual(DocPath("/v/\u{c5}.md"), DocPath("/v/\u{212b}.md"))
    }

    func testCombiningMarkAfterASlashStaysASlash() {
        XCTAssertNotEqual(DocPath("/v/\u{301}a.md"), DocPath("/v/a.md"))
    }
}
