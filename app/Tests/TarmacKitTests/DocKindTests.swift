import XCTest
@testable import TarmacKit

/// Spec 2607.0004 S1: kind is derived from the path extension alone.
final class DocKindTests: XCTestCase {
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
}
