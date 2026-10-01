import XCTest
@testable import TarmacKit

/// Spec 2607.0004: kind is derived from the path extension alone (S1), and a
/// card's content is addressed by a `tarmac-card://` URL (S2).
final class DocKindTests: XCTestCase {
    // MARK: - S1 routing

    func testHTMLAndHTMRouteToHTMLCaseInsensitively() {
        XCTAssertEqual(DocKind(path: "/a/b/a.html"), .html)
        XCTAssertEqual(DocKind(path: "/a/B.HTM"), .html)
        XCTAssertEqual(DocKind(path: "x.htm"), .html)
        XCTAssertEqual(DocKind(path: "/a/dash.HtMl"), .html)
    }

    func testEverythingElseRoutesToMarkdown() {
        XCTAssertEqual(DocKind(path: "/a/a.md"), .markdown)
        XCTAssertEqual(DocKind(path: "/a/a.html.bak"), .markdown)
        XCTAssertEqual(DocKind(path: "/a/README"), .markdown)
        XCTAssertEqual(DocKind(path: "/a/a.htmlx"), .markdown)
    }

    /// Dotfiles and degenerate names have no extension, as with Node's
    /// `path.extname` — which `NSString.pathExtension` does not match for `.html`.
    func testDotfilesAndTrailingDotsAreMarkdown() {
        XCTAssertEqual(DocKind(path: "/a/.html"), .markdown)
        XCTAssertEqual(DocKind(path: "/a/name."), .markdown)
        XCTAssertEqual(DocKind(path: "/a/.hidden.html"), .html)
    }

    func testADotInADirectoryNameIsNotAnExtension() {
        XCTAssertEqual(DocKind(path: "/a.html/README"), .markdown)
    }

    // MARK: - S2 card addressing

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
    /// reloading an HTML card and losing its JS state (#99). The two calls straddle
    /// a clock tick so a time-derived nonce cannot hide inside one millisecond.
    func testIsAPureFunctionOfPathAndMtime() {
        let first = CardURL.src(path: "/tmp/live.html", mtimeMs: 1_700_000_000_000)
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertEqual(CardURL.src(path: "/tmp/live.html", mtimeMs: 1_700_000_000_000), first)
    }
}
