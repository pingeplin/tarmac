import TarmacKit
import XCTest

/// Spec 2611.0013 "Unread count and badge text": the title-bar button's title.
final class InboxBadgeTests: XCTestCase {
    /// "Unread count and badge text".
    func testTheBadgeCountsUpTo99() {
        XCTAssertEqual(InboxBadge.text(unread: 0), "inbox")
        XCTAssertEqual(InboxBadge.text(unread: 7), "inbox · 7")
        XCTAssertEqual(InboxBadge.text(unread: 99), "inbox · 99")
        XCTAssertEqual(InboxBadge.text(unread: 100), "inbox · 99+")
    }
}
