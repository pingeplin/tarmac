import XCTest
@testable import TarmacKit

/// `tarmac dev snapshot --until <expr>` (spec 2609.0015, #166): a tiny,
/// hand-written predicate over a snapshot. An unresolvable path is false in both
/// polarities, so polling continues; a malformed expression is a parse error.
final class DevUntilTests: XCTestCase {
    private func term(width: Double = 800) -> JSONValue {
        let rect: JSONValue = ["x": 0, "y": 0, "w": .number(width), "h": 600]
        let state: JSONValue = [
            "cols": 80, "rows": 24, "proc": "sleep", "selection": nil, "scrollback_tail": "say hi\nhi",
        ]
        return ["id": "t-1", "kind": "term", "board_rect": rect, "focused": true, "term": state]
    }

    private func doc(_ id: String) -> JSONValue {
        let rect: JSONValue = ["x": 0, "y": 0, "w": 1, "h": 1]
        return ["id": .string(id), "kind": "doc", "board_rect": rect, "focused": false]
    }

    private func snapshot(zoom: Double = 0.5, cards: [JSONValue]? = nil) -> JSONValue {
        let viewport: JSONValue = ["zoom": .number(zoom), "cx": 0, "cy": 0]
        let all = cards ?? [term(), doc("/Users/e/a.b.md"), doc("/tmp/a]b.md")]
        return ["v": 1, "viewport": viewport, "cards": .array(all), "focused_card": "t-1"]
    }

    /// Parse-and-evaluate, failing loudly if the expression did not parse.
    private func holds(_ source: String, against: JSONValue? = nil) throws -> Bool {
        DevUntil.evaluate(try DevUntil.parse(source), against: against ?? snapshot())
    }

    // MARK: - S25 ==

    func testS25ComparesANumberAtADottedPath() throws {
        XCTAssertTrue(try holds("viewport.zoom == 0.5"))
        XCTAssertFalse(try holds("viewport.zoom == 0.5", against: snapshot(zoom: 1)))
    }

    // MARK: - S26 ~= is |Δ| ≤ 1

    private func approx(_ width: Double) throws -> Bool {
        try holds("cards[t-1].board_rect.w ~= 800", against: snapshot(cards: [term(width: width)]))
    }

    /// The load-bearing rows: at |Δ| = 1 a `< 1` implementation says false.
    func testS26AcceptsADeltaOfExactlyOneInBothDirections() throws {
        XCTAssertTrue(try approx(799))
        XCTAssertTrue(try approx(801))
    }

    func testS26AcceptsInsideTheBandAndRejectsOutsideIt() throws {
        XCTAssertTrue(try approx(799.4))
        XCTAssertTrue(try approx(800.9))
        XCTAssertFalse(try approx(798.9))
        XCTAssertFalse(try approx(801.5), "rules out a ≤ 2 band")
    }

    func testS26IsFalseWhenEitherSideIsNotANumber() throws {
        XCTAssertFalse(try holds("cards[t-1].kind ~= 800"))
        XCTAssertFalse(try holds(#"cards[t-1].board_rect.w ~= "800""#))
    }

    // MARK: - S27/S28 a bracketed card id is literal

    func testS27ResolvesAnIDContainingDotsAndSlashes() throws {
        // A naive split on "." would look for a `cards[/Users/e/a` card.
        XCTAssertFalse(try holds("cards[/Users/e/a.b.md].focused == true"))
        XCTAssertTrue(try holds(#"cards[/Users/e/a.b.md].kind == "doc""#))
    }

    func testS28RunsTheIDToTheLastBracketSoAnIDMayContainOne() throws {
        XCTAssertTrue(try holds(#"cards[/tmp/a]b.md].kind == "doc""#))
    }

    func testAPathResolvesPastABracketedIDToWhateverFollows() throws {
        XCTAssertTrue(try holds("cards[t-1].term.cols == 80"))
        XCTAssertTrue(try holds(#"cards[t-1].kind == "term""#))
    }

    // MARK: - S29 contains

    func testS29IsASubstringTestOnAString() throws {
        XCTAssertTrue(try holds(#"cards[t-1].term.scrollback_tail contains "hi""#))
        XCTAssertFalse(try holds(#"cards[t-1].term.scrollback_tail contains "nope""#))
    }

    /// `"abc".contains("")` is false in Swift; `includes("")` is true.
    func testS29TheEmptyStringIsContainedInAnyString() throws {
        XCTAssertTrue(try holds(#"cards[t-1].term.scrollback_tail contains """#))
    }

    func testS29TheNeedleMatchesByCodeUnitsNotByGraphemeCluster() throws {
        let tail: JSONValue = ["term": ["scrollback_tail": "e\u{301}"]]
        XCTAssertTrue(try holds(#"term.scrollback_tail contains "e""#, against: tail))
    }

    /// JavaScript's `===` compares code units, so a precomposed and a decomposed
    /// spelling of the same name are different ids; Swift's `String ==` would
    /// equate them.
    func testStringsAreEqualOnlyWhenTheirScalarsAre() throws {
        let decomposed: JSONValue = ["cards": [["id": "e\u{301}", "s": "e\u{301}"]]]
        XCTAssertTrue(try holds("cards[e\u{301}].s == \"e\u{301}\"", against: decomposed))
        XCTAssertFalse(try holds("cards[e\u{301}].s == \"\u{E9}\"", against: decomposed))
        XCTAssertTrue(try holds("cards[e\u{301}].s != \"\u{E9}\"", against: decomposed))
        XCTAssertFalse(try holds("cards[\u{E9}].s != \"x\"", against: decomposed), "a different id does not resolve")
    }

    // MARK: - S30 !=

    func testS30WorksAgainstAStringAndAgainstNull() throws {
        XCTAssertFalse(try holds(#"cards[t-1].term.proc != "sleep""#))
        XCTAssertTrue(try holds("cards[t-1].term.proc != null"))
        XCTAssertFalse(try holds("cards[t-1].term.selection != null"))
    }

    func testANullAtAResolvedPathIsAValueNotAMissingPath() throws {
        XCTAssertTrue(try holds("cards[t-1].term.selection == null"))
    }

    func testAnObjectOrArrayIsNeverEqualToAScalar() throws {
        XCTAssertFalse(try holds("viewport == 1"))
        XCTAssertTrue(try holds("viewport != 1"))
        XCTAssertFalse(try holds("cards == null"))
    }

    func testKeysAreFoundByUnicodeScalarsNotByCanonicalEquivalence() throws {
        let decomposedKey: JSONValue = ["e\u{301}": 1]
        XCTAssertTrue(try holds("e\u{301} == 1", against: decomposedKey))
        XCTAssertFalse(try holds("\u{E9} == 1", against: decomposedKey))
        XCTAssertFalse(try holds("\u{E9} != 1", against: decomposedKey), "unresolvable: neither polarity fires")
    }

    // MARK: - S31 an unresolvable path is false, not an error

    func testS31KeepsPollingForACardThatHasNotRenderedYet() throws {
        XCTAssertFalse(try holds("cards[t-9].term.cols == 80"))
        XCTAssertFalse(try holds("viewport.nope == 1"))
        XCTAssertFalse(try holds("cards[/Users/e/a.b.md].term.cols == 80"))
        // ...and `!=` against a missing path is false too: a path that does not
        // resolve makes no claim either way, so neither polarity may fire.
        XCTAssertFalse(try holds("cards[t-9].term.cols != 80"))
    }

    func testS31AnUnclosedBracketOrADescentThroughAScalarDoesNotResolve() throws {
        XCTAssertFalse(try holds("cards[t-1.kind == 1"))
        XCTAssertFalse(try holds("viewport.zoom.deeper == 1"))
        XCTAssertFalse(try holds("cards[t-1].kind.deeper != 1"))
    }

    // MARK: - S32 contains on a non-string

    func testS32IsFalseAndDoesNotThrow() throws {
        XCTAssertFalse(try holds(#"viewport.zoom contains "0""#))
        XCTAssertFalse(try holds(#"cards[t-1].term.selection contains "x""#))
        XCTAssertFalse(try holds("cards[t-1].term.scrollback_tail contains 5"))
    }

    // MARK: - S33 a malformed expression is a parse error, not false

    func testS33IsDistinguishableFromAnExpressionThatSimplyDoesNotHold() throws {
        for bad in ["viewport.zoom =! 0.5", #"cards[t-1].kind == "unterminated"#, "", "   ", "viewport.zoom", "== 1"] {
            XCTAssertThrowsError(try DevUntil.parse(bad), bad.debugDescription)
        }
        XCTAssertNoThrow(try DevUntil.parse("viewport.zoom == 1"))
    }

    func testS33TheErrorsSayWhatWasWrong() {
        XCTAssertEqual(parseError("   "), "empty expression")
        XCTAssertEqual(parseError("== 1"), "missing path")
        XCTAssertEqual(parseError("viewport.zoom"), #"expected <path> <op> <value>, got "viewport.zoom""#)
        XCTAssertEqual(parseError("a == banana"), #"not a value: "banana""#)
        XCTAssertEqual(parseError(#"a == "x" y"#), #"not a value: "\"x\" y""#)
    }

    private func parseError(_ source: String) -> String? {
        do {
            _ = try DevUntil.parse(source)
            return nil
        } catch let error as DevUntil.ParseError {
            return error.message
        } catch {
            return "unexpected \(error)"
        }
    }

    // MARK: - S34 value literals

    func testS34ParsesEachType() throws {
        func value(_ source: String) throws -> JSONValue {
            try DevUntil.parse("x == \(source)").value
        }
        XCTAssertEqual(try value("0.5"), 0.5)
        XCTAssertEqual(try value("-1"), -1)
        XCTAssertEqual(try value(#""a \"quoted\" \\ path""#), .string(#"a "quoted" \ path"#))
        XCTAssertEqual(try value("null"), nil)
        XCTAssertEqual(try value("true"), true)
        XCTAssertEqual(try value("false"), false)
    }

    func testAnEscapedNonSpecialCharacterStandsForItself() throws {
        XCTAssertEqual(try DevUntil.parse(#"x == "a\nb""#).value, .string("anb"))
    }

    func testANonFiniteOrJunkNumberIsNotAValue() {
        for junk in ["Infinity", "nan", "1e400", "1,5", "--1", "1 2"] {
            XCTAssertNotNil(parseError("x == \(junk)"), junk)
        }
    }

    /// The spec grammar promises decimal and exponent literals, and no more.
    func testNumbersAreDecimalOrExponentLiterals() throws {
        let literals: [(String, Double)] = [
            ("0", 0), ("007", 7), ("+5", 5), ("-2.5", -2.5), ("1e3", 1000), ("1E3", 1000),
            ("-1.5e-2", -0.015), ("2e+2", 200), (".5", 0.5), ("5.", 5),
        ]
        for (text, number) in literals {
            XCTAssertEqual(try DevUntil.parse("x == \(text)").value, .number(number), text)
        }
    }

    func testOtherNumberSpellingsAreNotValues() {
        let junk = [
            "0x10", "0X10", "0x1p4", "0b11", "0o17", "1_000", "1e", "e3", "1e+", "+", "-", ".", "1.2.3", "+-1",
            "\u{663}", "NaN", "inf", "0x",
        ]
        for text in junk {
            XCTAssertEqual(parseError("x == \(text)"), "not a value: \(JSONValue.string(text).jsonString)", text)
        }
    }

    // MARK: - grammar

    func testParsesEachOperator() throws {
        XCTAssertEqual(try DevUntil.parse("a.b == 1"), DevUntil.Expression(path: "a.b", op: .equal, value: 1))
        XCTAssertEqual(try DevUntil.parse("a.b != 1"), DevUntil.Expression(path: "a.b", op: .notEqual, value: 1))
        XCTAssertEqual(try DevUntil.parse("a.b ~= 1"), DevUntil.Expression(path: "a.b", op: .approximately, value: 1))
        XCTAssertEqual(try DevUntil.parse(#"a.b contains "x""#), DevUntil.Expression(path: "a.b", op: .contains, value: "x"))
    }

    func testSurroundingWhitespaceAndMissingSpacesAroundASymbolicOperatorAreFine() throws {
        XCTAssertEqual(try DevUntil.parse("  a.b==1  "), DevUntil.Expression(path: "a.b", op: .equal, value: 1))
    }

    /// `contains` is a word and needs whitespace on both sides, so a path that ends
    /// in it is still a path.
    func testAPathEndingInContainsIsNotMistakenForTheOperator() throws {
        XCTAssertEqual(try DevUntil.parse("a.contains == 1"), DevUntil.Expression(path: "a.contains", op: .equal, value: 1))
    }

    func testTheNumericToleranceIsOne() {
        XCTAssertEqual(DevUntil.numericTolerance, 1)
    }
}
