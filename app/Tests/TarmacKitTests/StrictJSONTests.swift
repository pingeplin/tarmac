import XCTest

@testable import TarmacKit

/// Whether a document is JSON that `serde_json::from_slice` would accept, at
/// the edges of each rule. The documents a real file holds are in
/// `AppPrefsStrictnessTests`.
final class StrictJSONTests: XCTestCase {
    private func valid(_ json: String) -> Bool { StrictJSON.isValid(Data(json.utf8)) }

    /// A JSON unicode escape, so each case below reads as the hex digits that
    /// matter rather than as a string literal that may or may not be an escape.
    private func u(_ hex: String) -> String { #"\u"# + hex }

    private func quoted(_ content: String) -> String { #"""# + content + #"""# }

    private func nested(_ depth: Int) -> String {
        String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    }

    func testAnyValueIsADocument() {
        for json in ["0", "-0", "1.5e-3", #""""#, "true", "false", "null", "[]", "{}", #"{"a":[1,{"b":null}]}"#] {
            XCTAssertTrue(valid(json), json)
        }
    }

    func testWhitespaceIsAllowedInsideAnEmptyContainerAndAroundEveryToken() {
        for json in ["[ ]", "{\t}", "[\r\n1 , 2\n]", #"{ "a" : 1 , "b" : 2 }"#, " \t\r\n0 \t\r\n"] {
            XCTAssertTrue(valid(json), json)
        }
    }

    func testANumberEndsWhereItsGrammarDoes() {
        for json in ["1.5.2", "01", "1.", "1e", "1e5e5", "--1", "1-", "1e400"] {
            XCTAssertFalse(valid(json), json)
        }
        for json in ["0e0", "0E+0", "1e-0", "-0.0"] {
            XCTAssertTrue(valid(json), json)
        }
    }

    func testOnlyTheSpellingOfALiteralIsALiteral() {
        for json in ["tru", "trve", "nall", "fakse", "falsey", "True"] {
            XCTAssertFalse(valid(json), json)
        }
    }

    func testTheRawByteJustBelowSpaceIsRefusedInAStringAndSpaceIsKept() {
        XCTAssertFalse(StrictJSON.isValid(Data([0x22, 0x1F, 0x22])))
        XCTAssertTrue(StrictJSON.isValid(Data([0x22, 0x20, 0x22])))
    }

    func testAStringNeedsItsClosingQuote() {
        for json in [#"""#, #""abc"#, #""a\""#] {
            XCTAssertFalse(valid(json), json)
        }
    }

    func testOnlyTheShortEscapesOfJSONAreEscapes() {
        for escape in [#"\""#, #"\\"#, #"\/"#, #"\b"#, #"\f"#, #"\n"#, #"\r"#, #"\t"#] {
            XCTAssertTrue(valid(quoted(escape)), escape)
        }
        for escape in [#"\a"#, #"\v"#, #"\0"#, #"\'"#, #"\x41"#, #"\U"# + "0041"] {
            XCTAssertFalse(valid(quoted(escape)), escape)
        }
    }

    func testAUnicodeEscapeNeedsFourHexDigits() {
        for escapes in [u(""), u("0"), u("00"), u("000"), u("d83d") + u("de0")] {
            XCTAssertFalse(valid(quoted(escapes)), escapes)
        }
    }

    func testHexDigitsAreZeroToNineAndAToFInEitherCase() {
        for digits in ["0009", "000a", "000f", "000A", "000F"] {
            XCTAssertTrue(valid(quoted(u(digits))), digits)
        }
        for digits in ["000/", "000:", "000@", "000G", "000`", "000g"] {
            XCTAssertFalse(valid(quoted(u(digits))), digits)
        }
    }

    func testOnlyAHighSurrogateFollowedByALowOneIsAPair() {
        for escapes in [u("d7ff"), u("e000"), u("ffff"), u("d800") + u("dc00"), u("dbff") + u("dfff")] {
            XCTAssertTrue(valid(quoted(escapes)), escapes)
        }
        let unpaired = [
            u("dc00"), u("dfff"), u("d800") + u("d800"), u("dbff") + u("e000"), u("d800") + u("dbff"),
            u("d800") + "xudc00",
        ]
        for escapes in unpaired {
            XCTAssertFalse(valid(quoted(escapes)), escapes)
        }
    }

    func testTheDocumentsOwnContainerCountsTowardTheDepth() {
        XCTAssertEqual(StrictJSON.maxDepth, 127)
        XCTAssertTrue(valid(nested(127)))
        XCTAssertFalse(valid(nested(128)))
        XCTAssertTrue(valid(String(repeating: #"{"a":"#, count: 127) + "0" + String(repeating: "}", count: 127)))
        XCTAssertFalse(valid(String(repeating: #"{"a":"#, count: 128) + "0" + String(repeating: "}", count: 128)))
    }

    func testElementsAndMembersAreSeparatedByOneComma() {
        for json in ["[1 2]", "[1,,2]", "[,1]", "[1,]", #"{"a":1 "b":2}"#] {
            XCTAssertFalse(valid(json), json)
        }
    }

    func testAMemberNeedsAStringKeyAndAColon() {
        for json in [#"{1:2}"#, #"{a":1}"#, #"{"a"}"#, #"{"a":}"#, #"{"a" 1}"#, #"{"a":1,}"#] {
            XCTAssertFalse(valid(json), json)
        }
    }

    /// The grammar alone takes any byte at or above 0x20 in a string: whether the
    /// bytes are UTF-8 is `isValid`'s to judge.
    func testTheGrammarAloneLeavesTheEncodingToItsCaller() {
        let notUTF8: [UInt8] = [0x22, 0xC3, 0x28, 0x22]
        XCTAssertTrue(StrictJSON.isValid(utf8: notUTF8))
        XCTAssertFalse(StrictJSON.isValid(Data(notUTF8)))
    }
}
