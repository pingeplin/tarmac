import XCTest
@testable import TarmacKit

/// The markdown doc page as it ships (`TarmacApp/Resources/DocTemplate.html`):
/// the policy every doc is rendered under, and the factor its prose is laid
/// out at.
final class DocTemplateTests: XCTestCase {
    private func template() throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: app.appendingPathComponent("Sources/TarmacApp/Resources/DocTemplate.html"), encoding: .utf8
        )
    }

    private func firstMatch(_ pattern: String, in text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "no match for \(pattern)"
        )
        return String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])
    }

    /// A doc's raw HTML never runs, embeds no plugin, and frames web pages
    /// only — never the card scheme, where a framed local file would sit
    /// unsandboxed beside an attacker's.
    func testTheContentSecurityPolicy() throws {
        let policy = try firstMatch(
            #"<meta http-equiv="Content-Security-Policy" content="([^"]*)">"#, in: try template()
        )
        XCTAssertEqual(policy, "script-src 'none'; object-src 'none'; frame-src http: https:")
    }

    func testThePolicyIsTheFirstThingInTheHead() throws {
        let text = try template()
        let head = try XCTUnwrap(text.range(of: "<head>"))
        let policy = try XCTUnwrap(text.range(of: "http-equiv=\"Content-Security-Policy\""))
        let between = text[head.upperBound..<policy.lowerBound]
        XCTAssertFalse(between.contains("<style"), "a style sheet ahead of the policy escapes it")
        XCTAssertFalse(between.contains("<script"))
    }

    /// The prose is laid out once at this factor and scaled down to the zoom.
    /// Below the board's max zoom the scale would be an upsample, and blur.
    func testTheOversampleFactorIsAtLeastTheBoardsMaxZoom() throws {
        let factor = try XCTUnwrap(Double(try firstMatch(#"--oversample-k:\s*([0-9.]+);"#, in: try template())))
        XCTAssertGreaterThanOrEqual(factor, Double(BoardZoom.max))
        XCTAssertLessThanOrEqual(Double(BoardZoom.max) / factor, 1)
    }
}
