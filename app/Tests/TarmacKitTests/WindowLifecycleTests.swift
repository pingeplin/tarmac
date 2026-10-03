import XCTest
@testable import TarmacKit

/// 2609.0016: who owes the window a comeback. Ported from the Rust
/// `window_lifecycle.rs` tests; S-numbers are the spec's.
final class WindowLifecycleTests: XCTestCase {
    /// S27 — activation and Reopen both fire for one Dock click.
    func testACloseIsWorthExactlyOneRestore() {
        let state = HiddenByClose()
        state.closeRequested()
        XCTAssertTrue(state.takeRestore())
        XCTAssertFalse(state.takeRestore())

        state.closeRequested()
        state.closeRequested()
        XCTAssertTrue(state.takeRestore())
        XCTAssertFalse(state.takeRestore())

        state.closeRequested()
        XCTAssertTrue(state.takeRestore())
    }

    /// S27b — nothing was hidden by the red button, so nothing is restored. The
    /// guard's own hide goes through no call at all.
    func testAnUntouchedWindowIsNeverRestored() {
        XCTAssertFalse(HiddenByClose().takeRestore())
    }
}
