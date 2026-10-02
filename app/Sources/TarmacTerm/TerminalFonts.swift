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
    /// The Nerd Font "Mono" variant keeps every icon glyph one cell wide.
    static let preferredNames = ["JetBrainsMonoNFM-Regular", "IBMPlexMono", "SFMono-Regular", "Menlo-Regular"]

    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let metrics: CellMetrics

    init(size: CGFloat, pixelsPerPoint: CGFloat, names: [String] = TerminalFonts.preferredNames) {
        let regular = Self.resolve(names, size: size)
        self.regular = regular
        bold = Self.variant(of: regular, .traitBold)
        italic = Self.variant(of: regular, .traitItalic)
        boldItalic = Self.variant(of: regular, [.traitBold, .traitItalic])
        metrics = Self.metrics(of: regular, pixelsPerPoint: max(pixelsPerPoint, 1))
    }

    func font(for flags: CellFlags) -> CTFont {
        switch (flags.contains(.bold), flags.contains(.italic)) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }

    private static func resolve(_ names: [String], size: CGFloat) -> CTFont {
        for name in names {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            // CoreText substitutes a default face for an unknown name instead of failing.
            if CTFontCopyPostScriptName(font) as String == name { return font }
        }
        return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
    }

    /// The family's face in `traits`. A family with no italic — the app ships
    /// regular and bold only — gives its upright face, slanted.
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
