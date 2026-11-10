import XCTest
@testable import TarmacKit

/// The content rule an HTML card's web view loads under, as WebKit is given it.
final class CardNetworkRuleTests: XCTestCase {
    private func rules() throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(CardNetworkRule.json.utf8)) as? [[String: Any]])
    }

    /// Two rules, and nothing in either that would let a load through: a
    /// trigger with a load context, a domain or a resource type would.
    func testTheTwoRulesBlockEveryWebAndSocketLoadInEveryFrame() throws {
        XCTAssertEqual(try rules() as NSArray, [
            ["trigger": ["url-filter": "^https?:"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?:"], "action": ["type": "block"]],
        ] as NSArray)
    }

    func testTheFiltersMatchTheNetworkSchemesAndNothingACardIsServed() throws {
        let filters = try rules().map { rule in
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            return try NSRegularExpression(pattern: try XCTUnwrap(trigger["url-filter"] as? String))
        }
        func blocked(_ url: String) -> Bool {
            filters.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }
        for url in ["http://a/", "https://a/", "ws://a/", "wss://a/"] {
            XCTAssertTrue(blocked(url), url)
        }
        for url in [
            CardURL.src(path: "/Users/me/card.html", mtimeMs: 7),
            CardURL.src(path: "/Users/me/shot.png", mtimeMs: 7, host: .img),
            "data:text/html,x", "blob:null/x", "about:blank", "about:srcdoc", "httpx://a/",
        ] {
            XCTAssertFalse(blocked(url), url)
        }
    }

    func testTheRuleIsStoredUnderItsOwnName() {
        XCTAssertFalse(CardNetworkRule.identifier.isEmpty)
        XCTAssertNotEqual(CardNetworkRule.identifier, DocFrameRule.identifier)
    }
}
