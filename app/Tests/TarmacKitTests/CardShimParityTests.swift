import XCTest

/// The native app serves the Tauri app's HTML-card shim unchanged: what a
/// card's document can observe of its host is the shim's behaviour, and the
/// shim's own tests live with the Tauri copy (`desktop/src/card-shim.test.ts`).
final class CardShimParityTests: XCTestCase {
    func testTheBundledShimIsTheTauriShimByteForByte() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tauri = repo.appendingPathComponent("desktop/src-tauri/src/card_shim.js")
        let bundled = repo.appendingPathComponent("app/Sources/TarmacApp/Resources/Web/card_shim.js")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: tauri.path),
            "desktop/src-tauri/src/card_shim.js is gone, so the app's copy is the shim now and there is nothing to hold it to; delete this test"
        )
        let shim = try Data(contentsOf: bundled)
        XCTAssertFalse(shim.isEmpty)
        XCTAssertEqual(shim, try Data(contentsOf: tauri))
    }
}
