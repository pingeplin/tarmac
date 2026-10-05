import AppKit
import CoreGraphics
import CoreText
import Foundation

struct CellMetrics: Equatable {
    /// One cell in points, a whole number of device pixels at zoom 1 so the grid
    /// lands on the pixel grid there.
    var cell: CGSize
    /// Baseline, measured down from the cell's top.
    var baseline: CGFloat
    var underlineOffset: CGFloat
    var strikethroughOffset: CGFloat
    var lineThickness: CGFloat
}

/// The terminal face in its four styles, plus the cell box they define.
struct TerminalFonts {
    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let metrics: CellMetrics

    init(size: CGFloat, pixelsPerPoint: CGFloat, family: String? = nil) {
        let regular = Self.resolve(family, size: size)
        self.regular = regular
        bold = Self.variant(of: regular, .traitBold)
        italic = Self.variant(of: regular, .traitItalic)
        boldItalic = Self.variant(of: regular, [.traitBold, .traitItalic])
        metrics = Self.metrics(of: regular, pixelsPerPoint: max(pixelsPerPoint, 1))
    }

    /// The face `text` is set in. Line-drawing characters are never italic: a
    /// rule that leans no longer meets the one in the row below.
    func font(for flags: CellFlags, drawing text: String) -> CTFont {
        font(for: Self.joinsItsNeighbours(text) ? flags.subtracting(.italic) : flags)
    }

    /// Box drawing, block elements and the Powerline separators.
    static func joinsItsNeighbours(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return (0x2500...0x259f).contains(scalar.value) || (0xe0b0...0xe0d7).contains(scalar.value)
    }

    func font(for flags: CellFlags) -> CTFont {
        switch (flags.contains(.bold), flags.contains(.italic)) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }

    /// The regular upright face of `family`, or the system's monospaced font
    /// for none and for a family this Mac does not have. The font manager is
    /// asked, not a CoreText descriptor: a family-only descriptor gives
    /// Helvetica for a name it does not know, and a Light face for some it does.
    fileprivate static func resolve(_ family: String?, size: CGFloat) -> CTFont {
        let named = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
        return named ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The family's face in `traits`. A family with no italic gives its
    /// upright face, slanted; one with no bold gives its regular face.
    private static func variant(of font: CTFont, _ traits: CTFontSymbolicTraits) -> CTFont {
        if let face = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) { return face }
        guard traits.contains(.traitItalic) else { return font }
        var slant = CGAffineTransform(a: 1, b: 0, c: syntheticSlant, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(variant(of: font, traits.subtracting(.traitItalic)), 0, &slant, nil)
    }

    /// The tangent of 11.5°, the lean of a typical oblique.
    private static let syntheticSlant: CGFloat = 0.2

    private static func metrics(of font: CTFont, pixelsPerPoint scale: CGFloat) -> CellMetrics {
        var glyph = CGGlyph(0)
        var character: UniChar = 0x4d
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let height = ((ascent + descent + CTFontGetLeading(font)) * scale).rounded(.up) / scale
        let width = max((advance.width * scale).rounded() / scale, 1 / scale)
        let baseline = (((height - ascent - descent) / 2 + ascent) * scale).rounded() / scale
        let thickness = max((CTFontGetUnderlineThickness(font) * scale).rounded() / scale, 1 / scale)
        return CellMetrics(
            cell: CGSize(width: width, height: height),
            baseline: baseline,
            underlineOffset: min(baseline - CTFontGetUnderlinePosition(font), height - thickness),
            strikethroughOffset: baseline - CTFontGetXHeight(font) / 2,
            lineThickness: thickness
        )
    }
}

public enum TerminalFace {
    /// The PostScript name of the regular face a terminal set in `family`
    /// draws with; nil asks for the system default's.
    public static func name(family: String?) -> String {
        CTFontCopyPostScriptName(TerminalFonts.resolve(family, size: 16)) as String
    }
}
