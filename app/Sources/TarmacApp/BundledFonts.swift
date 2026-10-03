import CoreText
import Foundation

/// The terminal and chrome faces ship with the app, so a card looks the same
/// on a machine that never installed them. Registered for this process only,
/// and before the first view resolves its font by name.
enum BundledFonts {
    private static let extensions = ["ttf", "woff2"]

    static func register() {
        // A bundled app carries its resources in Contents/Resources, where
        // `Bundle.module` finds no package bundle and traps.
        let packaged = fonts(in: .main)
        for font in packaged.isEmpty ? fonts(in: .module) : packaged {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }

    private static func fonts(in bundle: Bundle) -> [URL] {
        extensions.flatMap { bundle.urls(forResourcesWithExtension: $0, subdirectory: "Fonts") ?? [] }
    }
}
