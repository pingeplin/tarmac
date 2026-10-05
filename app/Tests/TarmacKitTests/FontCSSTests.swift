import XCTest
@testable import TarmacKit

/// 2610.0005: the `font-family` values a doc card is given.
final class FontCSSTests: XCTestCase {
    /// S9
    func testAFamilyIsPutBeforeItsRolesStack() {
        XCTAssertEqual(FontCSS.interface(nil), "ui-monospace, monospace")
        XCTAssertEqual(FontCSS.interface("Fira Code"), #""Fira Code", ui-monospace, monospace"#)
        XCTAssertEqual(FontCSS.document(nil), #"-apple-system, "SF Pro Text", system-ui, sans-serif"#)
        XCTAssertEqual(FontCSS.document("Georgia"), #""Georgia", -apple-system, "SF Pro Text", system-ui, sans-serif"#)
    }

    /// 2610.0006 S9
    func testAProseSizeIsALengthInPixels() {
        XCTAssertEqual(FontCSS.proseSize(14), "14px")
        XCTAssertEqual(FontCSS.proseSize(13.5), "13.5px")
    }

    /// S29 — a name cannot close its own string.
    func testQuotesAndBackslashesInANameAreEscaped() {
        XCTAssertEqual(FontCSS.interface(#"A"B\C"#), #""A\"B\\C", ui-monospace, monospace"#)
        XCTAssertEqual(FontCSS.document(#"A"B\C"#), #""A\"B\\C", -apple-system, "SF Pro Text", system-ui, sans-serif"#)
    }

    /// S29
    func testANameThatIsNotUsableGivesTheStackAlone() {
        for name in ["", "a\nb", "a\u{1f}b", "a\u{7f}b"] {
            XCTAssertEqual(FontCSS.interface(name), FontCSS.monospaceStack, name.debugDescription)
            XCTAssertEqual(FontCSS.document(name), FontCSS.proseStack, name.debugDescription)
        }
        XCTAssertEqual(FontCSS.interface("a b"), #""a b", ui-monospace, monospace"#)
    }
}
