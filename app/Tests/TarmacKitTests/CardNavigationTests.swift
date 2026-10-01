import XCTest
@testable import TarmacKit

/// Where a card's web view may navigate. A card never navigates itself away:
/// a markdown doc's http(s) link goes to the browser and every other href is
/// inert (spec 2607.0005); an HTML card's frame only ever holds a
/// `tarmac-card://doc/` document (spec 2607.0004).
final class CardNavigationTests: XCTestCase {
    private func click(_ url: String, target: CardNavigation.Target = .mainFrame) -> CardNavigation.Request {
        CardNavigation.Request(url: url, target: target, cause: .linkClick)
    }

    private func other(_ url: String, target: CardNavigation.Target) -> CardNavigation.Request {
        CardNavigation.Request(url: url, target: target, cause: .other)
    }

    private func pageLoad(_ url: String) -> CardNavigation.Request {
        CardNavigation.Request(url: url, target: .mainFrame, cause: .pageLoad)
    }

    // MARK: - markdown doc

    func testTheDocPagesOwnLoadIsAllowed() {
        XCTAssertEqual(CardNavigation.doc(pageLoad("about:blank")), .allow)
    }

    func testAClickedHTTPLinkOpensInTheBrowser() {
        for url in ["https://example.com/a?b#c", "http://example.com"] {
            XCTAssertEqual(CardNavigation.doc(click(url)), .openExternally, url)
        }
    }

    func testEveryOtherHrefIsInert() {
        for url in ["mailto:a@b.c", "file:///etc/passwd", "javascript:alert(1)", "about:blank#top", "tarmac-card://doc/%2Fa.html", "x.md"] {
            XCTAssertEqual(CardNavigation.doc(click(url)), .cancel, url)
        }
    }

    /// A link that asks for a new window is the same link.
    func testALinkToANewWindowGoesTheSameWay() {
        XCTAssertEqual(CardNavigation.doc(click("https://example.com", target: .newWindow)), .openExternally)
        XCTAssertEqual(CardNavigation.doc(click("file:///etc/passwd", target: .newWindow)), .cancel)
    }

    /// Raw HTML can carry a refresh or a form; only a click reaches the browser.
    func testANavigationNobodyClickedNeverOpensTheBrowser() {
        XCTAssertEqual(CardNavigation.doc(other("https://example.com", target: .mainFrame)), .cancel)
        XCTAssertEqual(CardNavigation.doc(other("https://example.com", target: .newWindow)), .cancel)
    }

    /// Raw HTML in a doc may hold an iframe; what loads inside it is its own.
    func testAnEmbeddedFrameOfADocMayLoad() {
        XCTAssertEqual(CardNavigation.doc(other("https://example.com/embed", target: .subframe)), .allow)
        XCTAssertEqual(CardNavigation.doc(click("https://example.com/next", target: .subframe)), .allow)
    }

    // MARK: - HTML card

    func testTheHostPagesOwnLoadIsAllowed() {
        XCTAssertEqual(CardNavigation.htmlCard(pageLoad("about:blank")), .allow)
    }

    func testTheHostPageNeverNavigatesAgain() {
        for url in ["https://example.com", "tarmac-card://doc/%2Fa.html", "about:blank"] {
            XCTAssertEqual(CardNavigation.htmlCard(click(url)), .cancel, url)
            XCTAssertEqual(CardNavigation.htmlCard(other(url, target: .mainFrame)), .cancel, url)
        }
    }

    func testTheCardsFrameMayLoadCardDocuments() {
        for url in ["tarmac-card://doc/%2Fr%2Fa.html?v=12", "tarmac-card://doc/%2Fr%2Fb.html"] {
            XCTAssertEqual(CardNavigation.htmlCard(other(url, target: .subframe)), .allow, url)
            XCTAssertEqual(CardNavigation.htmlCard(click(url, target: .subframe)), .allow, url)
        }
    }

    func testTheCardsFrameNeverLeavesTheCardScheme() {
        for url in ["https://example.com", "http://example.com", "file:///etc/passwd", "tarmac-card://img/%2Fa.png", "data:text/html,x"] {
            XCTAssertEqual(CardNavigation.htmlCard(other(url, target: .subframe)), .cancel, url)
            XCTAssertEqual(CardNavigation.htmlCard(click(url, target: .subframe)), .cancel, url)
        }
    }

    func testAnHTMLCardOpensNoWindow() {
        XCTAssertEqual(CardNavigation.htmlCard(click("tarmac-card://doc/%2Fa.html", target: .newWindow)), .cancel)
        XCTAssertEqual(CardNavigation.htmlCard(click("https://example.com", target: .newWindow)), .cancel)
    }
}
