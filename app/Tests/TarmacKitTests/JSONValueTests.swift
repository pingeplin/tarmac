import XCTest
@testable import TarmacKit

/// The JSON tree the card console relay and the QA driver's `--until` read.
/// Numbers carry JavaScript semantics (one `Double` type), so a snapshot's `1`
/// equals the expression's `1`.
final class JSONValueTests: XCTestCase {
    private func json(_ value: JSONValue) -> JSONValue { value }

    // MARK: - literals

    func testLiteralsBuildTheTree() {
        let value: JSONValue = ["a": 1, "b": [true, nil, "s", 0.5]]
        XCTAssertEqual(
            value,
            .object([
                "a": .number(1),
                "b": .array([.bool(true), .null, .string("s"), .number(0.5)]),
            ])
        )
    }

    // MARK: - init(foundation:)

    func testBridgesWhatAWebViewMessageBodyCarries() throws {
        let body: [String: Any] = [
            "s": "text", "i": 3, "d": 2.5, "yes": true, "no": false, "nothing": NSNull(),
            "list": [1, "x"] as [Any], "nested": ["k": "v"] as [String: Any],
        ]
        XCTAssertEqual(
            JSONValue(foundation: body),
            ["s": "text", "i": 3, "d": 2.5, "yes": true, "no": false, "nothing": nil,
             "list": [1, "x"], "nested": ["k": "v"]]
        )
    }

    /// An NSNumber 1 is not the Boolean true, though both bridge to `Bool`.
    func testTellsAnNSNumberFromABoolean() throws {
        XCTAssertEqual(JSONValue(foundation: NSNumber(value: 1)), .number(1))
        XCTAssertEqual(JSONValue(foundation: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(JSONValue(foundation: NSNumber(value: 0)), .number(0))
        XCTAssertEqual(JSONValue(foundation: NSNumber(value: false)), .bool(false))
    }

    func testBridgesJSONSerializationOutput() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(#"{"a":true,"b":1,"c":null,"d":[1,{"e":"f"}]}"#.utf8)
        )
        XCTAssertEqual(
            JSONValue(foundation: object),
            ["a": true, "b": 1, "c": nil, "d": [1, ["e": "f"]]]
        )
    }

    func testRejectsAValueJSONCannotCarry() {
        XCTAssertNil(JSONValue(foundation: Date()))
        XCTAssertNil(JSONValue(foundation: ["k": Date()] as [String: Any]))
        XCTAssertNil(JSONValue(foundation: [Date()] as [Any]))
    }

    // MARK: - jsonString

    func testJSONStringIsCompactWithKeysSorted() {
        XCTAssertEqual(json(["b": 1, "a": "x"]).jsonString, #"{"a":"x","b":1}"#)
        XCTAssertEqual(json([1, 2]).jsonString, "[1,2]")
        XCTAssertEqual(json([:]).jsonString, "{}")
        XCTAssertEqual(json([]).jsonString, "[]")
        XCTAssertEqual(json([["a": [1]]]).jsonString, #"[{"a":[1]}]"#)
    }

    func testJSONStringEscapesLikeJSONStringify() {
        XCTAssertEqual(JSONValue.string("a\"b\\c\nd\te").jsonString, #""a\"b\\c\nd\te""#)
        XCTAssertEqual(JSONValue.string("\u{01}\u{08}\u{0C}\r").jsonString, #""\u0001\b\f\r""#)
        XCTAssertEqual(JSONValue.string("a/b 圖").jsonString, "\"a/b 圖\"", "no slash escape, non-ASCII kept")
    }

    func testJSONStringOfScalars() {
        XCTAssertEqual(JSONValue.null.jsonString, "null")
        XCTAssertEqual(JSONValue.bool(true).jsonString, "true")
        XCTAssertEqual(JSONValue.number(0.5).jsonString, "0.5")
        XCTAssertEqual(JSONValue.number(.nan).jsonString, "null", "JSON has no NaN")
        XCTAssertEqual(JSONValue.number(.infinity).jsonString, "null")
    }

    // MARK: - displayString

    func testDisplayStringIsTheScalarsPlainTextAndCompositesAsJSON() {
        XCTAssertEqual(JSONValue.string("tick").displayString, "tick")
        XCTAssertEqual(JSONValue.number(42).displayString, "42")
        XCTAssertEqual(JSONValue.bool(true).displayString, "true")
        XCTAssertEqual(JSONValue.null.displayString, "null")
        XCTAssertEqual(json(["a": 1]).displayString, #"{"a":1}"#)
        XCTAssertEqual(json([1, 2]).displayString, "[1,2]")
    }

    func testDisplayStringOfNumbersReadsLikeJavaScript() {
        XCTAssertEqual(JSONValue.number(1.5).displayString, "1.5")
        XCTAssertEqual(JSONValue.number(-3).displayString, "-3")
        XCTAssertEqual(JSONValue.number(-0.0).displayString, "0")
        XCTAssertEqual(JSONValue.number(9_007_199_254_740_991).displayString, "9007199254740991")
        XCTAssertEqual(JSONValue.number(1e21).displayString, "1e+21")
        XCTAssertEqual(JSONValue.number(.nan).displayString, "NaN")
        XCTAssertEqual(JSONValue.number(.infinity).displayString, "Infinity")
        XCTAssertEqual(JSONValue.number(-.infinity).displayString, "-Infinity")
    }

    /// ECMAScript's Number::toString: the shortest round-trip digits, written out in
    /// full up to 10^21 and down to 10^-6, in exponent form beyond — where Swift's
    /// own `description` switches earlier and pads exponents to two digits.
    func testNumbersUseECMAScriptNumberToStringLayout() {
        let cases: [(Double, String)] = [
            (100, "100"), (0.1, "0.1"), (0.1 + 0.2, "0.30000000000000004"), (12345678.9, "12345678.9"),
            (9_007_199_254_740_992, "9007199254740992"), (1e16, "10000000000000000"),
            (1.2345678901234568e20, "123456789012345680000"), (1e21, "1e+21"), (1.5e21, "1.5e+21"),
            (0.000001, "0.000001"), (1e-7, "1e-7"), (1.5e-7, "1.5e-7"), (-1e-7, "-1e-7"),
            (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (1e100, "1e+100"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(JSONValue.number(value).displayString, text)
            XCTAssertEqual(JSONValue.number(value).jsonString, text, "JSON.stringify writes the same digits")
        }
    }
}
