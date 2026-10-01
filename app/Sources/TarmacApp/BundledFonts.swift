import CoreText
import Foundation

/// The terminal face ships with the app, so a terminal card looks the same on
/// a machine that never installed it. Registered for this process only, and
/// before the first terminal view resolves its font by name.
enum BundledFonts {
    static func register() {
        // A bundled app carries its resources in Contents/Resources, where
        // `Bundle.module` finds no package bundle and traps.
        let packaged = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        let fonts = packaged.isEmpty
            ? Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
            : packaged
        for font in fonts {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }
}
