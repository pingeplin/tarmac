import AppKit
import TarmacKit

/// What this Mac says of its font families: the facts `FontMenu` and
/// `FontRole.familyInEffect` decide from.
@MainActor
enum InstalledFonts {
    /// Every family. About 190 ms in a fresh process, so not for launch.
    static func all() -> [InstalledFamily] {
        NSFontManager.shared.availableFontFamilies.compactMap(facts)
    }

    /// One family, under the Mac's own spelling of its name: the lookup is
    /// not case-sensitive, and a saved `menlo` must not pass for `Menlo`.
    static func family(named name: String) -> InstalledFamily? {
        NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: NSFont.systemFontSize)?
            .familyName.flatMap(facts)
    }

    /// A member is `[PostScript name, style, weight, traits]`. Which of them
    /// speaks for the family is `InstalledFamily`'s decision.
    private static func facts(of family: String) -> InstalledFamily? {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return InstalledFamily(name: family, faces: members.compactMap { member in
            guard member.count >= 4, let weight = member[2] as? Int, let traits = member[3] as? UInt else { return nil }
            let mask = NSFontTraitMask(rawValue: traits)
            return InstalledFamily.Face(
                weight: weight, italic: mask.contains(.italicFontMask), fixedPitch: mask.contains(.fixedPitchFontMask)
            )
        })
    }
}
