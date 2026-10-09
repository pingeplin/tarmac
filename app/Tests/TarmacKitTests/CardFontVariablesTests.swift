import JavaScriptCore
import XCTest
@testable import TarmacKit

/// The three CSS properties an HTML card is given for the user's fonts
/// (spec 2610.0010): their values, the one escaping of the JSON they travel
/// in, and the shim marker they fill.
final class CardFontVariablesTests: XCTestCase {
    private func variables(interface: String? = nil, document: String? = nil, size: Double = 14) -> CardFontVariables {
        CardFontVariables(interfaceFamily: interface, documentFamily: document, documentSize: size)
    }

    private func parsed(_ json: String) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: String])
    }

    // MARK: - values

    func test2610_0010S2NothingChosenGivesTheStacksAndTheStandardSize() {
        XCTAssertEqual(
            variables().json,
            #"{"--tarmac-mono-font":"ui-monospace, monospace","--tarmac-prose-font":"-apple-system, \"SF Pro Text\", system-ui, sans-serif","--tarmac-prose-size":"14px"}"#
        )
    }

    func test2610_0010S3EachValueIsWhatFontCSSGivesForItsOwnInput() throws {
        let chosen = try parsed(variables(interface: "Fira Code", document: "Georgia", size: 13.5).json)
        XCTAssertEqual(chosen[CardFontVariables.monoFont], FontCSS.interface("Fira Code"))
        XCTAssertEqual(chosen[CardFontVariables.proseFont], FontCSS.document("Georgia"))
        XCTAssertEqual(chosen[CardFontVariables.proseSize], FontCSS.proseSize(13.5))

        let base = try parsed(variables().json)
        let size = try parsed(variables(size: 20).json)
        XCTAssertEqual(size[CardFontVariables.proseSize], "20px")
        XCTAssertEqual(size[CardFontVariables.monoFont], base[CardFontVariables.monoFont])
        XCTAssertEqual(size[CardFontVariables.proseFont], base[CardFontVariables.proseFont])

        let document = try parsed(variables(document: "Georgia").json)
        XCTAssertEqual(document[CardFontVariables.monoFont], base[CardFontVariables.monoFont])
        XCTAssertEqual(document[CardFontVariables.proseSize], base[CardFontVariables.proseSize])
        XCTAssertNotEqual(document[CardFontVariables.proseFont], base[CardFontVariables.proseFont])

        let interface = try parsed(variables(interface: "Menlo").json)
        XCTAssertEqual(interface[CardFontVariables.proseFont], base[CardFontVariables.proseFont])
        XCTAssertEqual(interface[CardFontVariables.proseSize], base[CardFontVariables.proseSize])
        XCTAssertNotEqual(interface[CardFontVariables.monoFont], base[CardFontVariables.monoFont])
    }

    func test2610_0010S4AFamilyThatIsEmptyOrHoldsAControlCharacterGivesTheStackAlone() throws {
        for name in ["", "Geo\u{0}rgia", "a\nb", "a\u{7f}b"] {
            let both = try parsed(variables(interface: name, document: name).json)
            XCTAssertEqual(both[CardFontVariables.monoFont], FontCSS.monospaceStack, name.debugDescription)
            XCTAssertEqual(both[CardFontVariables.proseFont], FontCSS.proseStack, name.debugDescription)
        }
    }

    // MARK: - escaping

    private static let hostile = [
        "</script><script>x</script>", "<!--", #"a"b\c"#, "a'b", "a`b", "${x}", "*/",
        "a\u{2028}b\u{2029}c", #"\<"#, #"\\<"#,
    ]

    func test2610_0010S6TheJSONHoldsNoLessThanAndNoRawLineSeparatorAndIsAValidLiteral() throws {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("the literal threw: \(String(describing: error))") }
        for name in Self.hostile {
            let json = variables(interface: name, document: name).json
            XCTAssertFalse(json.contains("<"), "< in \(name.debugDescription)")
            XCTAssertFalse(json.contains("\u{2028}") || json.contains("\u{2029}"), "raw separator in \(name.debugDescription)")

            let literal = try XCTUnwrap(context.evaluateScript("(\(json))"), name)
            XCTAssertEqual(literal.forProperty(CardFontVariables.monoFont).toString(), FontCSS.interface(name), name.debugDescription)
            XCTAssertEqual(literal.forProperty(CardFontVariables.proseFont).toString(), FontCSS.document(name), name.debugDescription)
            XCTAssertEqual(try parsed(json)[CardFontVariables.monoFont], FontCSS.interface(name), name.debugDescription)
        }
    }

    // MARK: - the marker

    private func shim(markers: Int) -> String {
        let marker = CardFontVariables.marker
        return (0..<markers).reduce("var a = 1;\n") { $0 + "var b\($1) = [\(marker)][0];\n" } + "var z = 2;\n"
    }

    func test2610_0010S7TheMarkerIsReplacedByTheJSONWhenTheShimHoldsItOnce() {
        let fonts = variables(interface: "Menlo")
        let once = shim(markers: 1)
        let filled = fonts.filling(once)
        XCTAssertEqual(filled, once.replacingOccurrences(of: CardFontVariables.marker, with: fonts.json))
        XCTAssertFalse(filled.contains(CardFontVariables.marker))
        XCTAssertTrue(filled.contains(fonts.json))
    }

    func test2610_0010S7AShimWithNoMarkerOrTwoIsGivenBackAsItIs() {
        let fonts = variables()
        for count in [0, 2] {
            let text = shim(markers: count)
            XCTAssertEqual(fonts.filling(text), text, "\(count) markers")
        }
    }

    func test2610_0010S7AFamilyNamedLikeTheMarkerIsNotSearchedAgain() {
        let fonts = variables(interface: CardFontVariables.marker)
        let filled = fonts.filling(shim(markers: 1))
        XCTAssertEqual(filled, shim(markers: 1).replacingOccurrences(of: CardFontVariables.marker, with: fonts.json))
        XCTAssertTrue(filled.contains(CardFontVariables.marker))
    }

    // MARK: - the guide (S25)

    private func guide() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("core/crates/tarmac-cli/src/GUIDE.md"), encoding: .utf8
        )
    }

    private func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func test2610_0010S25TheGuideNamesTheThreePropertiesAndNoLongerSaysTheSystemStackIsTheOnlyChoice() throws {
        let guide = try guide()
        for name in [CardFontVariables.proseSize, CardFontVariables.proseFont, CardFontVariables.monoFont] {
            XCTAssertTrue(guide.contains(name), name)
        }
        let section = try XCTUnwrap(guide.components(separatedBy: "### The user's fonts\n").dropFirst().first, "the section")
        let example = try XCTUnwrap(section.components(separatedBy: "```html\n").dropFirst().first?.components(separatedBy: "```").first, "the example")
        for name in [CardFontVariables.proseSize, CardFontVariables.proseFont, CardFontVariables.monoFont] {
            XCTAssertTrue(example.contains("var(\(name), "), "a use of \(name) with a fallback")
        }
        let checklist = guide.split(separator: "\n").filter { $0.hasPrefix("- [ ]") }
        XCTAssertTrue(checklist.contains { $0.contains("--tarmac-") }, "a checklist line")

        let flat = collapsed(guide)
        XCTAssertFalse(flat.contains("All CSS in a `<style>` block; system font stack."))
        XCTAssertFalse(flat.contains("Use an inline `<style>` and a system font stack."))
    }
}
