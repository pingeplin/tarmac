import XCTest
@testable import TarmacKit

/// The content rule a markdown doc's web view loads under, as WebKit is given it.
final class DocFrameRuleTests: XCTestCase {
    private func rules() throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DocFrameRule.json.utf8)) as? [[String: Any]])
    }

    /// One rule, and nothing in it that would let a load through: a trigger
    /// with an `if-` or `unless-` condition would.
    func testTheOneRuleBlocksTheImgHostInChildFrames() throws {
        let rules = try rules()
        XCTAssertEqual(rules.count, 1)
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule as NSDictionary, [
            "trigger": ["url-filter": "^tarmac-card://img/", "load-context": ["child-frame"]],
            "action": ["type": "block"],
        ] as NSDictionary)
    }

    func testTheFilterMatchesEveryImageURLTheAppBuildsAndNoOtherURL() throws {
        let trigger = try XCTUnwrap(try rules().first?["trigger"] as? [String: Any])
        let filter = try NSRegularExpression(pattern: try XCTUnwrap(trigger["url-filter"] as? String))
        func matches(_ url: String) -> Bool {
            filter.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        XCTAssertTrue(matches(CardURL.src(path: "/Users/me/shot 1.png", mtimeMs: 7, host: .img)))
        XCTAssertTrue(matches(ImageProtocol.uriPrefix))
        XCTAssertFalse(matches(CardURL.src(path: "/Users/me/card.html", mtimeMs: 7)))
        XCTAssertFalse(matches("https://example.com/tarmac-card://img/x.png"))
    }
}
