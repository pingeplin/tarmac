import CoreText
import Foundation

/// The terminal's tests measure the face the app ships, whatever the machine
/// has installed: it is registered for this process from the app's resources.
enum ShippedFonts {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TarmacApp/Resources/Fonts")

    static var files: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".ttf") }.sorted().map(folder.appendingPathComponent)
    }

    static let registered: Void = {
        for file in files { CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) }
    }()
}
