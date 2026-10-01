import XCTest
@testable import TarmacKit

/// Only absolute http(s) hrefs may reach the OS opener; everything else stays
/// inert so the card webview never navigates itself away.
final class ExternalLinkTests: XCTestCase {
    func testAcceptsAbsoluteHTTPSURLs() {
        XCTAssertTrue(ExternalLink.isHTTP(href: "https://x.com"))
    }

    func testAcceptsAbsoluteHTTPURLs() {
        XCTAssertTrue(ExternalLink.isHTTP(href: "http://x.com"))
    }

    func testRejectsRelativeHrefs() {
        XCTAssertFalse(ExternalLink.isHTTP(href: "#section"))
        XCTAssertFalse(ExternalLink.isHTTP(href: "/local/path"))
        XCTAssertFalse(ExternalLink.isHTTP(href: "//x.com"))
        XCTAssertFalse(ExternalLink.isHTTP(href: ""))
    }

    func testRejectsNonHTTPSchemes() {
        XCTAssertFalse(ExternalLink.isHTTP(href: "mailto:a@b.com"))
        XCTAssertFalse(ExternalLink.isHTTP(href: "javascript:alert(1)"))
        XCTAssertFalse(ExternalLink.isHTTP(href: "ftp://x"))
        XCTAssertFalse(ExternalLink.isHTTP(href: "file:///a"))
    }

    func testTheSchemeIsCaseInsensitive() {
        XCTAssertTrue(ExternalLink.isHTTP(href: "HTTPS://X.COM"))
    }

    /// The URL standard strips leading/trailing C0 controls and spaces and every
    /// tab and newline before parsing, so an href written that way still opens.
    func testStripsWhatTheURLStandardStripsBeforeParsing() {
        XCTAssertTrue(ExternalLink.isHTTP(href: " https://x.com"))
        XCTAssertTrue(ExternalLink.isHTTP(href: "\thttps://x.com\n"))
        XCTAssertTrue(ExternalLink.isHTTP(href: "ht\ntps://x.com"))
    }

    func testRejectsAnHTTPURLWithoutAHost() {
        XCTAssertFalse(ExternalLink.isHTTP(href: "https://"))
        XCTAssertFalse(ExternalLink.isHTTP(href: "http://:80"))
        XCTAssertFalse(ExternalLink.isHTTP(href: "https:"))
    }

    func testRejectsAnInvalidHost() {
        XCTAssertFalse(ExternalLink.isHTTP(href: "https://x y.com"))
    }

    /// Stricter than the URL standard, which would read `https:x.com` as
    /// `https://x.com`: a link needs an explicit authority to leave the app.
    func testRejectsAnHTTPSchemeWithoutAnAuthority() {
        XCTAssertFalse(ExternalLink.isHTTP(href: "https:x.com"))
        XCTAssertFalse(ExternalLink.isHTTP(href: "https:/x.com"))
    }

    func testAcceptsAParsedURLByItsScheme() throws {
        XCTAssertTrue(ExternalLink.isHTTP(try XCTUnwrap(URL(string: "https://x.com/a?b=c#d"))))
        XCTAssertFalse(ExternalLink.isHTTP(try XCTUnwrap(URL(string: "mailto:a@b.com"))))
    }
}
