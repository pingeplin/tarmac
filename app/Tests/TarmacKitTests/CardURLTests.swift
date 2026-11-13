import XCTest
@testable import TarmacKit

/// Spec 2607.0004 S2: a card's content is addressed by a `tarmac-card://` URL.
final class CardURLTests: XCTestCase {
    func testPercentEncodesTheWholePathAsOneSegmentWithTheMtimeVersion() {
        let url = CardURL.src(path: "/Users/me/my dash.html", mtimeMs: 1234)
        XCTAssertEqual(url, "tarmac-card://doc/%2FUsers%2Fme%2Fmy%20dash.html?v=1234")
        XCTAssertFalse(url.dropFirst("tarmac-card://doc/".count).contains("/"), "one segment, not a nested path")
    }

    func testEncodesReservedAndNonASCIICharacters() throws {
        let path = "/tmp/圖表 100%#?.html"
        let url = CardURL.src(path: path, mtimeMs: 7)
        XCTAssertEqual(url, "tarmac-card://doc/%2Ftmp%2F%E5%9C%96%E8%A1%A8%20100%25%23%3F.html?v=7")
        let segment = try XCTUnwrap(url.split(separator: "/", omittingEmptySubsequences: false).last?.split(separator: "?").first)
        XCTAssertEqual(String(segment).removingPercentEncoding, path)
    }

    /// Exactly the characters `encodeURIComponent` leaves alone.
    func testKeepsTheUnreservedPunctuationEncodeURIComponentKeeps() {
        XCTAssertEqual(CardURL.src(path: "a!~*'()-_.b", mtimeMs: 0), "tarmac-card://doc/a!~*'()-_.b?v=0")
    }

    func testAMissingMtimeFallsBackToVersionZero() {
        XCTAssertTrue(CardURL.src(path: "/a.html", mtimeMs: nil).hasSuffix("?v=0"))
    }

    func testTheImageHostAddressesMarkdownDocCardImages() {
        XCTAssertEqual(CardURL.src(path: "/a/x.png", mtimeMs: 5, host: .img), "tarmac-card://img/%2Fa%2Fx.png?v=5")
    }

    /// Spec 2609.0001 S11 — a standing guard: the refresh control re-evaluates this
    /// on every click, so purity is what keeps an unchanged-mtime refresh from
    /// reloading an HTML card and losing its JS state (#99). The URL is pinned to
    /// the exact string, so any time-derived nonce or counter in it fails at once —
    /// which two back-to-back calls could not promise within one clock tick.
    func testIsAPureFunctionOfPathAndMtime() {
        let expected = "tarmac-card://doc/%2Ftmp%2Flive.html?v=1700000000000"
        XCTAssertEqual(CardURL.src(path: "/tmp/live.html", mtimeMs: 1_700_000_000_000), expected)
        XCTAssertEqual(CardURL.src(path: "/tmp/live.html", mtimeMs: 1_700_000_000_000), expected)
    }
}
