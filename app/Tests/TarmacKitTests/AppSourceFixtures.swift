import Foundation

/// A file of the app's source tree as it ships, read by a test that checks
/// what is bundled: a page template or a page script.
enum AppSource {
    static func text(_ path: String, from file: String = #filePath) throws -> String {
        let app = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent("Sources/TarmacApp/\(path)"), encoding: .utf8)
    }
}
