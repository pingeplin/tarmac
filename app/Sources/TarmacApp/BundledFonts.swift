import CoreText
import Foundation

/// The terminal face ships with the app, so a terminal card looks the same on
/// a machine that never installed it. Registered for this process only, and
/// before the first terminal view resolves its font by name.
enum BundledFonts {
    static func register() {
        let fonts = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for font in fonts {
            // A failure is a copy the user already installed, which serves as well.
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }
}
