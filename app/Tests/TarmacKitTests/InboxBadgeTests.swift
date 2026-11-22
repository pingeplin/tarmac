import TarmacKit
import XCTest

/// Spec 2611.0013 S9: the title-bar button's title.
final class InboxBadgeTests: XCTestCase {
    func testS9TheBadgeCountsUpTo99() {
        XCTAssertEqual(InboxBadge.text(unread: 0), "inbox")
        XCTAssertEqual(InboxBadge.text(unread: 7), "inbox · 7")
        XCTAssertEqual(InboxBadge.text(unread: 99), "inbox · 99")
        XCTAssertEqual(InboxBadge.text(unread: 100), "inbox · 99+")
    }
}
