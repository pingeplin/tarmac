import AppKit
import CoreText
import XCTest
@testable import TarmacTerm

final class TerminalFontsTests: XCTestCase {
    private func fonts(_ family: String?) -> TerminalFonts {
        TerminalFonts(size: 16, pixelsPerPoint: 2, family: family)
    }

    private func name(_ font: CTFont) -> String {
        CTFontCopyPostScriptName(font) as String
    }

    private var systemFace: String {
        NSFont.monospacedSystemFont(ofSize: 16, weight: .regular).fontName
    }

    private func isItalic(_ font: CTFont) -> Bool {
        CTFontGetSymbolicTraits(font).contains(.traitItalic)
    }

    /// How far the top of a vertical bar is drawn to the right of its foot, in pixels.
    private func lean(of font: CTFont) throws -> Int {
        let side = 64
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        var character: UniChar = 0x7c
        var glyph = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var position = CGPoint(x: 24, y: 24)
        context.setFillColor(gray: 1, alpha: 1)
        CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func firstInk(inRow row: Int) -> Int? { (0..<side).first { pixels[row * side + $0] > 127 } }
        let inked = (0..<side).filter { firstInk(inRow: $0) != nil }
        let top = try XCTUnwrap(inked.first.flatMap(firstInk)), foot = try XCTUnwrap(inked.last.flatMap(firstInk))
        return top - foot
    }

    /// 2610.0005 S10 — the app ships no face: with no family chosen the
    /// terminal is set in the system's monospaced font, which has real italics.
    func testWithNoFamilyTheFaceIsTheSystemMonospacedFont() {
        let system = fonts(nil)
        XCTAssertEqual(name(system.regular), systemFace)
        XCTAssertTrue(CTFontGetSymbolicTraits(system.regular).contains(.traitMonoSpace))
        for face in [system.italic, system.boldItalic] {
            XCTAssertTrue(isItalic(face))
            XCTAssertEqual(CTFontGetMatrix(face), .identity)
        }
        XCTAssertTrue(CTFontGetSymbolicTraits(system.boldItalic).contains(.traitBold))
        XCTAssertEqual(TerminalFace.name(family: nil), systemFace)
    }

    /// S11
    func testAFamilyGivesItsRegularAndBoldFaces() {
        let menlo = fonts("Menlo")
        XCTAssertEqual(name(menlo.regular), "Menlo-Regular")
        XCTAssertEqual(name(menlo.bold), "Menlo-Bold")
        XCTAssertEqual(TerminalFace.name(family: "Menlo"), "Menlo-Regular")
    }

    /// S30 — CoreText gives Helvetica for a name it does not know.
    func testAFamilyThatIsNotInstalledGivesTheSystemFace() {
        let missing = "No Such Family 204"
        XCTAssertEqual(name(fonts(missing).regular), systemFace)
        XCTAssertEqual(TerminalFace.name(family: missing), systemFace)
        XCTAssertEqual(fonts(missing).metrics, fonts(nil).metrics)
    }

    func testAFamilyWithAnItalicUsesIt() throws {
        let menlo = fonts("Menlo")
        XCTAssertTrue(isItalic(menlo.italic))
        XCTAssertTrue(isItalic(menlo.boldItalic))
        XCTAssertEqual(CTFontGetMatrix(menlo.italic), .identity)
    }

    /// Monaco has one face: italic text must still lean.
    func testAFamilyWithNoItalicIsSlanted() throws {
        let monaco = fonts("Monaco")
        XCTAssertFalse(isItalic(monaco.regular))
        XCTAssertEqual(try lean(of: monaco.regular), 0)
        XCTAssertGreaterThanOrEqual(try lean(of: monaco.italic), 2)
        XCTAssertGreaterThanOrEqual(try lean(of: monaco.boldItalic), 2)
    }

    /// PT Mono has a bold and no italic.
    func testASlantedBoldItalicIsTheBoldFace() throws {
        let ptMono = fonts("PT Mono")
        try XCTSkipUnless(CTFontCopyPostScriptName(ptMono.regular) as String == "PTMono-Regular", "PT Mono is not installed")
        XCTAssertTrue(CTFontGetSymbolicTraits(ptMono.boldItalic).contains(.traitBold))
        XCTAssertFalse(CTFontGetSymbolicTraits(ptMono.italic).contains(.traitBold))
        XCTAssertGreaterThanOrEqual(try lean(of: ptMono.boldItalic), 2)
    }

    func testLineDrawingCharactersAreSetUpright() {
        let monaco = fonts("Monaco")
        for joiner in ["─", "│", "╬", "█", "▒", "\u{e0b0}"] {
            XCTAssertEqual(CTFontGetMatrix(monaco.font(for: [.italic], drawing: joiner)), .identity, joiner)
        }
        XCTAssertNotEqual(CTFontGetMatrix(monaco.font(for: [.italic], drawing: "|")), .identity)
    }
}
