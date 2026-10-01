import XCTest
@testable import TarmacKit

/// 2606.0004: ⌘W "close the focused card" routing (issue #15).
final class FocusedCloseTests: XCTestCase {
    /// Nothing focused ⇒ no-op, regardless of the live-terminal count.
    func testNoneIsNoop() {
        XCTAssertEqual(FocusedClose.decide(kind: .none, otherLiveTerminals: 0), .noop)
        XCTAssertEqual(FocusedClose.decide(kind: .none, otherLiveTerminals: 3), .noop)
    }

    /// A focused doc always shelves (recoverable), independent of terminals.
    func testDocShelves() {
        XCTAssertEqual(FocusedClose.decide(kind: .doc, otherLiveTerminals: 0), .shelfDoc)
        XCTAssertEqual(FocusedClose.decide(kind: .doc, otherLiveTerminals: 3), .shelfDoc)
    }

    /// A focused terminal closes; `replace` is true ONLY when it was the last live
    /// terminal (otherLive == 0), mirroring the clean-exit last-terminal guarantee.
    /// The 0→replace / 1→undo boundary is the load-bearing anti-mutation pin (it
    /// fails if `replace` is hard-wired or keyed off the wrong threshold).
    func testTerminalReplacesOnlyWhenLast() {
        XCTAssertEqual(FocusedClose.decide(kind: .term, otherLiveTerminals: 0, dead: false), .closeTerminal(replace: true, signalClose: true))
        XCTAssertEqual(FocusedClose.decide(kind: .term, otherLiveTerminals: 1, dead: false), .closeTerminal(replace: false, signalClose: true))
        XCTAssertEqual(FocusedClose.decide(kind: .term, otherLiveTerminals: 5, dead: false), .closeTerminal(replace: false, signalClose: true))
    }

    /// Omitting `dead` is the same as `false` — pins the default for a caller that
    /// has no dead state to report.
    func testOmittedDeadDefaultsToFalse() {
        XCTAssertEqual(FocusedClose.decide(kind: .term, otherLiveTerminals: 0), .closeTerminal(replace: true, signalClose: true))
        XCTAssertEqual(FocusedClose.decide(kind: .term, otherLiveTerminals: 3), .closeTerminal(replace: false, signalClose: true))
    }

    /// A dead terminal has no live pty to signal: `signalClose` is false whatever
    /// `otherLive` is, while `replace` keeps its `otherLive == 0` rule. Both
    /// assertions fail if `signalClose` ignores `dead`.
    func testDeadTerminalNeverSignalsCloseButReplaceIsUnaffected() {
        XCTAssertEqual(FocusedClose.decide(kind: .term, otherLiveTerminals: 0, dead: true), .closeTerminal(replace: true, signalClose: false))
        XCTAssertEqual(FocusedClose.decide(kind: .term, otherLiveTerminals: 3, dead: true), .closeTerminal(replace: false, signalClose: false))
    }

    /// `dead` means nothing for a doc or an empty focus — it must not regress them.
    func testDeadIsIgnoredForDocAndNone() {
        XCTAssertEqual(FocusedClose.decide(kind: .doc, otherLiveTerminals: 0, dead: true), .shelfDoc)
        XCTAssertEqual(FocusedClose.decide(kind: .none, otherLiveTerminals: 0, dead: true), .noop)
    }
}
