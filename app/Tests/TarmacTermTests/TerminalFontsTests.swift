import CoreText
import XCTest
@testable import TarmacTerm

final class TerminalFontsTests: XCTestCase {
    private func fonts(_ name: String) -> TerminalFonts {
        TerminalFonts(size: 16, pixelsPerPoint: 2, names: [name])
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

    /// The fonts the app ships are found by the name the terminal asks for first.
    func testTheShippedFaceIsTheOneTheTerminalAsksForFirst() throws {
        let shipped = ShippedFonts.files.flatMap { file -> [String] in
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []
            return descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        }
        XCTAssertTrue(shipped.contains(try XCTUnwrap(TerminalFonts.preferredNames.first)), "\(shipped)")
    }

    func testAFamilyWithAnItalicUsesIt() throws {
        let menlo = fonts("Menlo-Regular")
        XCTAssertTrue(isItalic(menlo.italic))
        XCTAssertTrue(isItalic(menlo.boldItalic))
        XCTAssertEqual(CTFontGetMatrix(menlo.italic), .identity)
    }

    /// The app ships regular and bold only: italic text must still lean.
    func testAFamilyWithNoItalicIsSlanted() throws {
        let monaco = fonts("Monaco")
        XCTAssertFalse(isItalic(monaco.regular))
        XCTAssertEqual(try lean(of: monaco.regular), 0)
        XCTAssertGreaterThanOrEqual(try lean(of: monaco.italic), 2)
        XCTAssertGreaterThanOrEqual(try lean(of: monaco.boldItalic), 2)
    }

    override func setUp() {
        ShippedFonts.registered
    }
}
