import XCTest
@testable import TarmacKit

/// 2609.0016: the rule is "anything serde_json would reject reads as guard ON".
/// Every input below carries an explicit `false`, so a parser lenient enough to
/// accept it turns the guard off. Each outcome was read off serde_json
/// (`serde_json::from_slice::<Value>`, as `app_prefs.rs` does), not off this
/// implementation.
///
/// Known differences, left unpinned, are listed on `AppPrefs.warnBeforeQuit`.
final class AppPrefsStrictnessTests: XCTestCase {
    private func bytes(_ json: String) -> Data { Data(json.utf8) }

    /// A JSON unicode escape, so each case below reads as the hex digits that
    /// matter rather than as a string literal that may or may not be an escape.
    private func u(_ hex: String) -> String { #"\u"# + hex }

    private func off(_ rest: String = "") -> String { #"{"warn_before_quit":false"# + rest + "}" }

    /// A document whose `x` string holds exactly `raw`, whatever those bytes are.
    private func stringMember(_ raw: [UInt8]) -> Data {
        bytes(#"{"warn_before_quit":false,"x":""#) + Data(raw) + bytes(#""}"#)
    }

    private func nested(_ depth: Int) -> String {
        String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    }

    private func nestedObjects(_ depth: Int) -> String {
        String(repeating: #"{"a":"#, count: depth) + "0" + String(repeating: "}", count: depth)
    }

    private func nestedMixed(_ depth: Int) -> String {
        var open = "", close = ""
        for level in 0..<depth {
            if level.isMultiple(of: 2) {
                open += "["
                close = "]" + close
            } else {
                open += #"{"a":"#
                close = "}" + close
            }
        }
        return open + "0" + close
    }

    private func assertGuardOn(_ cases: [(name: String, contents: Data)], file: StaticString = #filePath, line: UInt = #line) {
        for (name, contents) in cases {
            XCTAssertTrue(AppPrefs.warnBeforeQuit(from: contents), name, file: file, line: line)
            XCTAssertFalse(StrictJSON.isValid(contents), "\(name): not JSON to serde_json", file: file, line: line)
        }
    }

    // MARK: - Bytes

    /// Only UTF-8 is JSON here. `JSONDecoder` sniffs UTF-16 and UTF-32 and would
    /// read an `off` out of them.
    func testAnotherEncodingReadsAsGuardOn() {
        let text = off()
        let utf16le = text.data(using: .utf16LittleEndian)!
        let utf16be = text.data(using: .utf16BigEndian)!
        let utf32le = text.data(using: .utf32LittleEndian)!
        let utf32be = text.data(using: .utf32BigEndian)!
        assertGuardOn([
            ("UTF-16 LE with BOM", Data([0xFF, 0xFE]) + utf16le),
            ("UTF-16 BE with BOM", Data([0xFE, 0xFF]) + utf16be),
            ("UTF-16 LE", utf16le),
            ("UTF-16 BE", utf16be),
            ("UTF-32 LE with BOM", Data([0xFF, 0xFE, 0, 0]) + utf32le),
            ("UTF-32 BE with BOM", Data([0, 0, 0xFE, 0xFF]) + utf32be),
            ("UTF-32 LE", utf32le),
            ("UTF-32 BE", utf32be),
            ("UTF-8 with BOM", Data([0xEF, 0xBB, 0xBF]) + bytes(text)),
        ])
    }

    func testInvalidUTF8ReadsAsGuardOn() {
        let sequences: [(String, [UInt8])] = [
            ("invalid continuation", [0xC3, 0x28]),
            ("overlong NUL", [0xC0, 0x80]),
            ("encoded surrogate", [0xED, 0xA0, 0x80]),
            ("lead byte beyond U+10FFFF", [0xF5, 0x80, 0x80, 0x80]),
            ("truncated sequence", [0xE2, 0x82]),
            ("lone continuation byte", [0x80]),
        ]
        assertGuardOn(sequences.map { ($0.0, stringMember($0.1)) })
        XCTAssertFalse(AppPrefs.warnBeforeQuit(from: stringMember([0x61, 0x62])), "the same document with valid bytes")
    }

    /// Below U+0020 only space-like tab, LF and CR may appear, and never inside
    /// a string.
    func testRawControlCharactersReadAsGuardOn() {
        let inString: [(String, [UInt8])] = [
            ("NUL", [0x00]), ("0x01", [0x01]), ("tab", [0x09]), ("LF", [0x0A]), ("CR", [0x0D]),
        ]
        assertGuardOn(inString.map { ("\($0.0) in a string", stringMember([0x61] + $0.1 + [0x62])) })
        assertGuardOn([
            ("vertical tab as whitespace", Data([0x0B]) + bytes(off())),
            ("form feed as whitespace", Data([0x0C]) + bytes(off())),
            ("trailing NUL", bytes(off()) + Data([0x00])),
            ("0x01 in a key", bytes(#"{"x"#) + Data([0x01]) + bytes(#"":1,"warn_before_quit":false}"#)),
        ])
    }

    // MARK: - Grammar

    func testBrokenStructureReadsAsGuardOn() {
        let documents: [(String, String)] = [
            ("trailing comma in the object", #"{"warn_before_quit":false,}"#),
            ("trailing comma in an array", off(#","x":[1,]"#)),
            ("leading comma", #"{,"warn_before_quit":false}"#),
            ("double comma", #"{"warn_before_quit":false,,"x":1}"#),
            ("missing comma", #"{"warn_before_quit":false "x":1}"#),
            ("missing colon", #"{"warn_before_quit" false}"#),
            ("trailing garbage", off() + " junk"),
            ("extra closing brace", off() + "}"),
            ("two documents", off() + off()),
            ("truncated", #"{"warn_before_quit":false"#),
            ("single quotes", "{'warn_before_quit':false}"),
            ("unquoted key", "{warn_before_quit:false}"),
            ("key opened with the wrong quote", #"{'warn_before_quit":false}"#),
            ("line comment", off() + "\n// c"),
            ("block comment before", "/* c */" + off()),
            ("block comment inside", #"{"warn_before_quit":false/* c */}"#),
            ("capitalised literal", #"{"warn_before_quit":False}"#),
            ("truncated literal", #"{"warn_before_quit":fals}"#),
            ("empty file", ""),
            ("whitespace only", " \n"),
        ]
        assertGuardOn(documents.map { ($0.0, bytes($0.1)) })
    }

    func testMalformedNumbersReadAsGuardOn() {
        let literals = [
            "01", "-01", "1.", ".5", "+1", "-", "1e", "1e+", "1.e5", "0.", "0x1", "NaN", "Infinity", "-Infinity",
            "1e999", "-1e999", String(repeating: "9", count: 400), "-" + String(repeating: "9", count: 400),
        ]
        assertGuardOn(literals.map { ("x = \($0.prefix(12))", bytes(off(",\"x\":\($0)"))) })
    }

    func testMalformedStringEscapesReadAsGuardOn() {
        let strings: [(String, String)] = [
            ("lone high surrogate", u("d800")),
            ("lone upper-case high surrogate", u("D83D")),
            ("lone low surrogate", u("dc00")),
            ("high surrogate then a non-surrogate escape", u("d800") + u("0041")),
            ("high surrogate then a character", u("d800") + "x"),
            ("low surrogate then high", u("dc00") + u("d800")),
            ("short unicode escape", u("12")),
            ("non-hex unicode escape", u("12g4")),
            ("unknown escape", #"\x"#),
        ]
        assertGuardOn(strings.map { ($0.0, bytes(off(",\"x\":\"\($0.1)\""))) })
        assertGuardOn([
            ("unterminated string", bytes(off(#","x":"abc"#))),
            ("lone surrogate in a key", bytes(#"{""# + u("d800") + #"":1,"warn_before_quit":false}"#)),
        ])
    }

    /// serde_json stops at 128 levels: 127 nested containers are read, the
    /// 128th is an error. The document's own object is the first level.
    func testNestingBeyondSerdeJsonsLimitReadsAsGuardOn() {
        assertGuardOn([127, 128, 129, 200, 600].map { ("\($0) arrays deep", bytes(off(#","x":"# + nested($0)))) })
        assertGuardOn([127, 128, 200].map { ("\($0) objects deep", bytes(off(#","x":"# + nestedObjects($0)))) })
        assertGuardOn([127, 128].map { ("\($0) mixed deep", bytes(off(#","x":"# + nestedMixed($0)))) })
        assertGuardOn([("a million open brackets", bytes(off(#","x":"# + String(repeating: "[", count: 1_000_000))))])
    }

    // MARK: - Still accepted

    /// The checks above must not turn a valid file away: serde_json accepts all
    /// of these, so the explicit `false` still turns the guard off.
    func testEverythingSerdeJsonAcceptsStillTurnsTheGuardOff() {
        let documents: [(String, String)] = [
            ("plain", off()),
            ("whitespace around", " \t\r\n" + #"{ "warn_before_quit" : false }"# + "\n"),
            ("escaped key", #"{"warn"# + u("005f") + #"before_quit":false}"#),
            ("surrogate pair", off(#","x":""# + u("d83d") + u("de00") + #"""#)),
            ("upper-case hex digits", off(#","x":""# + u("00E9") + u("D83D") + u("DE00") + #"""#)),
            ("NUL escape", off(#","x":""# + u("0000") + #"""#)),
            ("every short escape", off(#","x":"\/\"\\\b\f\n\r\t""#)),
            ("raw UTF-8", off(#","x":"é😀""#)),
            ("DEL, U+2028 and a noncharacter", off(",\"x\":\"\u{7f}\u{2028}\u{FFFE}\"")),
            ("numbers", off(#","x":[0,-0,1.5e-3,1E5,1e+2,123456789012345678901234567890,1e308,-1.0]"#)),
            ("underflow to zero", off(#","x":1e-999"#)),
            ("negative zero exponent", off(#","x":-0.0e0"#)),
            ("long fraction", off(",\"x\":1." + String(repeating: "9", count: 400))),
            ("nested values", off(#","x":{"y":[null,true,{}]}"#)),
            ("100 arrays deep", off(#","x":"# + nested(100))),
            ("126 arrays deep, 127 levels", off(#","x":"# + nested(126))),
            ("126 objects deep, 127 levels", off(#","x":"# + nestedObjects(126))),
            ("126 mixed deep, 127 levels", off(#","x":"# + nestedMixed(126))),
        ]
        for (name, json) in documents {
            XCTAssertFalse(AppPrefs.warnBeforeQuit(from: bytes(json)), name)
            XCTAssertTrue(StrictJSON.isValid(bytes(json)), "\(name): valid to serde_json")
        }
    }
}
