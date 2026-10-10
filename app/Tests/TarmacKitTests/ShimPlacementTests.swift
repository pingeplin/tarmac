import XCTest
@testable import TarmacKit

/// Where the card shim's `<script>` goes (spec 2610.0011). Every vector is literal
/// bytes with a fixed offset, checked against two independent scratch
/// implementations of the rule.
final class ShimPlacementTests: XCTestCase {
    private let doctype = "<!doctype html>"
    private let rest = "<p>x</p>"
    private let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    private func offset(_ text: String) -> Int {
        ShimPlacement.offset(in: Data(text.utf8))
    }

    private func offset(_ bytes: [UInt8]) -> Int {
        ShimPlacement.offset(in: Data(bytes))
    }

    private func assertOffsets(
        _ vectors: [(prefix: String, offset: Int)], file: StaticString = #filePath, line: UInt = #line
    ) {
        for vector in vectors {
            XCTAssertEqual(offset(vector.prefix + doctype + rest), vector.offset, vector.prefix.debugDescription, file: file, line: line)
        }
    }

    /// A slice at an offset outside the file would trap and stop the whole run.
    private func assertRest(
        of file: Data, at offset: Int, is expected: String, file path: StaticString = #filePath, line: UInt = #line
    ) {
        guard (0...file.count).contains(offset) else {
            return XCTFail("offset \(offset) is outside 0...\(file.count)", file: path, line: line)
        }
        XCTAssertEqual(file[(file.startIndex + offset)...], Data(expected.utf8), file: path, line: line)
    }

    func testS1TheOffsetIsOnePastTheFirstGreaterThanOfALeadingDoctype() {
        let file = Data("<!doctype html><p>x</p>".utf8)
        let at = ShimPlacement.offset(in: file)
        XCTAssertEqual(at, 15)
        assertRest(of: file, at: at, is: rest)
        XCTAssertEqual(offset("<!DOCTYPE HTML><p>x</p>"), 15)
        XCTAssertEqual(offset("<!DocType html><p>x</p>"), 15)
        XCTAssertEqual(offset("<!doctypehtml><p>x</p>"), 14)
        XCTAssertEqual(offset(doctype), 15)
    }

    func testS2WhatTheBrowserSkipsBeforeADoctypeIsBeforeTheScript() {
        assertOffsets([
            ("\u{FEFF}", 18),
            ("\t", 16), ("\n", 16), ("\u{0C}", 16), ("\r", 16), (" ", 16),
            ("<!-- n -->", 25),
            ("<!-- a -->\n<!-- b -->\n  ", 39),
            ("<?xml version=\"1.0\"?>\n", 37),
            ("<?x>", 19), ("<?>", 18),
            ("\u{FEFF}\n<!-- c -->\n", 30),
            ("<!-- <!doctype html> > -->\n", 42),
        ])
    }

    func testS3BothCommentClosersEndAComment() {
        assertOffsets([
            ("<!-- x -->", 25), ("<!-- x --!>", 26),
            ("<!-->", 20), ("<!--->", 21), ("<!---->", 22), ("<!----!>", 23),
            ("<!-- a <!--> ", 28), ("<!-- a <!---> ", 29), ("<!-- a <!-- b --> ", 33),
        ])
        XCTAssertEqual(offset("<!-- a --!> b -->\n" + doctype + rest), 0)
        XCTAssertEqual(offset("<!---!>\n" + doctype + rest), 0)
        XCTAssertEqual(offset("<!---!>" + doctype + "<p>in</p> -->"), 0)
    }

    func testS4ADoctypeEndsAtItsFirstGreaterThanWhateverItHolds() {
        let vectors: [(String, Int)] = [
            ("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\">", 63),
            ("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\" \"http://www.w3.org/TR/html4/loose.dtd\">", 102),
            ("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">", 90),
            ("<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">", 121),
            ("<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">", 109),
            ("<!DOCTYPE html SYSTEM \"about:legacy-compat\">", 44),
            ("<!doctype>", 10),
            ("<!DOCTYPE html PUBLIC \"-//W3C//DTD>X\" >", 35),
        ]
        for (doctype, at) in vectors {
            XCTAssertEqual(offset(doctype + rest), at, doctype)
        }
        XCTAssertEqual(offset("<!doctype html <html><p>x</p>"), 21)
    }

    func testS5AFileWithNoLeadingDoctypeGetsTheStartOfTheFile() {
        let vectors: [(String, [UInt8])] = [
            ("empty", []),
            ("no doctype", Array("<html><p>x</p></html>".utf8)),
            ("text first", Array(("hello\n" + doctype + rest).utf8)),
            ("tag first", Array(("<html>" + doctype + rest).utf8)),
            ("doctype in a comment", Array(("<!-- " + doctype + " -->" + rest).utf8)),
            ("control bytes", [0, 1, 2] + Array(rest.utf8)),
            ("UTF-16LE with a BOM", [0xFF, 0xFE, 0x3C, 0x00, 0x70, 0x00, 0x3E, 0x00]),
            ("short doctype word", Array("<!doctyp".utf8)),
            ("doctype with no >", Array("<!doctype html".utf8)),
            ("unclosed comment", Array(("<!-- never closed\n" + doctype + rest).utf8)),
            ("unclosed <?", Array(("<?xml version=\"1.0\"" + doctype).utf8)),
            ("BOM after a space", [0x20] + bom + Array((doctype + rest).utf8)),
            ("tag then doctype", Array((rest + doctype + rest).utf8)),
            ("VT is not white space", Array(("\u{0B}" + doctype + rest).utf8)),
            ("NBSP is not white space", [0xC2, 0xA0] + Array((doctype + rest).utf8)),
            ("a closed short word", Array(("<!doctyp>" + rest).utf8)),
            ("unclosed comment after white space", Array("\n<!-- never closed".utf8)),
            ("unclosed <? after white space", Array(" <?x".utf8)),
            ("doctype with no > after white space", Array("\n<!doctype html".utf8)),
        ]
        for (name, bytes) in vectors {
            XCTAssertEqual(offset(bytes), 0, name)
        }
    }

    func testS6ABomAndNoDoctypeGivesTheBomLength() {
        XCTAssertEqual(offset(bom), 3)
        XCTAssertEqual(offset(bom + Array("<html>bom</html>".utf8)), 3)
        XCTAssertEqual(offset(bom + Array("<!-- x".utf8)), 3)
        XCTAssertEqual(offset(bom + Array("<?x".utf8)), 3)
        XCTAssertEqual(offset(bom + Array("\n<!-- x".utf8)), 3)
        XCTAssertEqual(offset(bom + Array(" <?x".utf8)), 3)
    }

    func testS7TheOffsetCountsFromTheStartOfASlice() {
        let slice = Data("zz".utf8 + Data("<!doctype html><p>x</p>".utf8))[2...]
        XCTAssertNotEqual(slice.startIndex, 0)
        let at = ShimPlacement.offset(in: slice)
        XCTAssertEqual(at, 15)
        assertRest(of: slice, at: at, is: rest)
    }
}
