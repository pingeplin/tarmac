import Foundation

/// The HTML card shim as it ships, read from the source tree.
enum CardShimSource {
    static func text() throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: app.appendingPathComponent("Sources/TarmacApp/Resources/Web/card_shim.js"), encoding: .utf8
        )
    }
}
