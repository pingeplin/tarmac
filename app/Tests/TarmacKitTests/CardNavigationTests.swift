import XCTest
@testable import TarmacKit

/// Where a card's web view may navigate. A card never navigates itself away:
/// a markdown doc's page loads once and no navigation opens the browser — its
/// links are opened from the page's own click, by their raw `href`
/// (`ExternalLink`); an HTML card's frame only ever holds a
/// `tarmac-card://doc/` document (spec 2607.0004).
final class CardNavigationTests: XCTestCase {
    private func load(_ url: String) -> CardNavigation.Request {
        CardNavigation.Request(url: url, target: .mainFrame, pageLoad: true)
    }

    private func later(_ url: String, target: CardNavigation.Target) -> CardNavigation.Request {
        CardNavigation.Request(url: url, target: target, pageLoad: false)
    }

    // MARK: - markdown doc

    /// A doc whose web view carries `DocFrameRule`, as every one does unless
    /// WebKit could not compile the rule.
    private func doc(_ request: CardNavigation.Request) -> CardNavigation.Verdict {
        CardNavigation.doc(request, framesGuarded: true)
    }

    func testTheDocPagesOwnLoadIsAllowed() {
        XCTAssertEqual(doc(load("about:blank")), .allow)
    }

    /// Whatever asks — a link, a form, a refresh, or a page the doc framed
    /// following a `_top` link of its own making — the doc's page stays.
    func testTheDocPageNeverNavigatesAgain() {
        for url in [
            "https://example.com/a", "http://example.com", "mailto:a@b.c", "file:///etc/passwd",
            "about:blank#top", "tarmac-card://doc/%2Fa.html", "javascript:alert(1)",
        ] {
            XCTAssertEqual(doc(later(url, target: .mainFrame)), .cancel, url)
        }
    }

    func testADocOpensNoWindow() {
        XCTAssertEqual(doc(later("https://example.com", target: .newWindow)), .cancel)
        XCTAssertEqual(doc(later("about:blank", target: .newWindow)), .cancel)
    }

    /// Raw HTML in a doc may embed a web page, as it may in the Tauri app.
    func testAFrameEmbeddedByADocMayLoadAWebPage() {
        for url in ["https://example.com/embed", "http://127.0.0.1:8080/x", "HTTPS://EXAMPLE.COM/UP"] {
            XCTAssertEqual(doc(later(url, target: .subframe)), .allow, url)
        }
    }

    /// A framed page that could reach the img host would learn which local
    /// images exist. With no rule to stop it, no web page is framed at all.
    func testWithoutTheFrameRuleADocFramesNoWebPage() {
        for url in ["https://example.com/embed", "http://127.0.0.1:8080/x"] {
            XCTAssertEqual(CardNavigation.doc(later(url, target: .subframe), framesGuarded: false), .cancel, url)
        }
    }

    func testWithoutTheFrameRuleTheDocItselfStillLoads() {
        XCTAssertEqual(CardNavigation.doc(load("about:blank"), framesGuarded: false), .allow)
        XCTAssertEqual(CardNavigation.doc(later("about:blank", target: .subframe), framesGuarded: false), .allow)
        XCTAssertEqual(CardNavigation.doc(later("about:srcdoc", target: .subframe), framesGuarded: false), .allow)
        XCTAssertEqual(CardNavigation.doc(later("https://example.com", target: .mainFrame), framesGuarded: false), .cancel)
    }

    func testAnEmptyOrInlineFrameOfADocMayLoad() {
        XCTAssertEqual(doc(later("about:blank", target: .subframe)), .allow)
        XCTAssertEqual(doc(later("about:srcdoc", target: .subframe)), .allow)
    }

    /// A card document framed by a markdown doc is not sandboxed: it would run
    /// at the scheme's own origin and read any other local file framed beside it.
    func testAFrameOfADocNeverLoadsTheCardScheme() {
        for url in [
            "tarmac-card://doc/%2Fr%2Fa.html?v=1", "tarmac-card://doc/%2Fetc%2Fpasswd",
            "tarmac-card://img/%2Fr%2Fa.svg", "TARMAC-CARD://DOC/%2Fr%2Fa.html", "tarmac-card:x",
        ] {
            XCTAssertEqual(doc(later(url, target: .subframe)), .cancel, url)
        }
    }

    func testAFrameOfADocLoadsNothingElseEither() {
        for url in ["file:///etc/passwd", "data:text/html,<script>1</script>", "blob:null/1", "x-evil://do/thing", ""] {
            XCTAssertEqual(doc(later(url, target: .subframe)), .cancel, url)
        }
    }

    // MARK: - HTML card

    func testTheHostPagesOwnLoadIsAllowed() {
        XCTAssertEqual(CardNavigation.htmlCard(load("about:blank")), .allow)
    }

    func testTheHostPageNeverNavigatesAgain() {
        for url in ["https://example.com", "tarmac-card://doc/%2Fa.html", "about:blank"] {
            XCTAssertEqual(CardNavigation.htmlCard(later(url, target: .mainFrame)), .cancel, url)
        }
    }

    func testTheCardsFrameMayLoadCardDocuments() {
        for url in ["tarmac-card://doc/%2Fr%2Fa.html?v=12", "tarmac-card://doc/%2Fr%2Fb.html"] {
            XCTAssertEqual(CardNavigation.htmlCard(later(url, target: .subframe)), .allow, url)
        }
    }

    func testTheCardsFrameNeverLeavesTheCardScheme() {
        for url in ["https://example.com", "http://example.com", "file:///etc/passwd", "tarmac-card://img/%2Fa.png", "data:text/html,x"] {
            XCTAssertEqual(CardNavigation.htmlCard(later(url, target: .subframe)), .cancel, url)
        }
    }

    /// The card scheme has to be where the URL starts, not somewhere in it.
    func testAURLThatOnlyMentionsTheCardSchemeIsNotACardDocument() {
        XCTAssertEqual(
            CardNavigation.htmlCard(later("https://example.com/?u=tarmac-card://doc/%2Fa.html", target: .subframe)),
            .cancel
        )
    }

    func testAnHTMLCardOpensNoWindow() {
        XCTAssertEqual(CardNavigation.htmlCard(later("tarmac-card://doc/%2Fa.html", target: .newWindow)), .cancel)
        XCTAssertEqual(CardNavigation.htmlCard(later("https://example.com", target: .newWindow)), .cancel)
    }

    func testOnlyTheTwoInlineFramesAreAboutURLsADocMayFrame() {
        for url in ["about:blank#x", "about:blank?x", "about:config", "about:"] {
            XCTAssertEqual(doc(.init(url: url, target: .subframe, pageLoad: false)), .cancel, url)
        }
    }

    func testASchemeThatOnlyStartsWithHTTPIsNotAWebPage() {
        for url in ["httpx://example.com/", "http-evil://a", "https+x://a", "http:evil", "https:"] {
            XCTAssertEqual(doc(.init(url: url, target: .subframe, pageLoad: false)), .cancel, url)
        }
    }
}
