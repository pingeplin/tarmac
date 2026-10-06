import XCTest
@testable import TarmacKit

/// 2610.0008: whether a palette is news to a page that is already loaded.
final class PageThemeTests: XCTestCase {
    private func palette(_ id: String) -> Palette { ThemeCatalog.theme(id).palette }

    /// S57 — from a dark theme to a dark theme is a change.
    func testS57APaletteIsNewsOnlyWhenItDiffersFromTheOneThePageHas() {
        var page = PageTheme(palette("breeze-dark"))

        XCTAssertFalse(page.take(palette("breeze-dark")))
        XCTAssertTrue(page.take(palette("catppuccin-mocha")))
        XCTAssertFalse(page.take(palette("catppuccin-mocha")))
        XCTAssertTrue(page.take(palette("breeze-dark")))
    }
}
