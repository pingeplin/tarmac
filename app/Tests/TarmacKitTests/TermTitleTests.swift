import XCTest
@testable import TarmacKit

/// The OSC-title vs process-name precedence rule and the "live" predicate.
final class TermTitleTests: XCTestCase {
    // MARK: displayLabel

    /// A non-empty OSC title wins over the foreground process name (Ghostty
    /// semantics): the program is showing what it wants shown.
    func testOSCTitleWinsOverProcName() {
        XCTAssertEqual(
            TermTitle.displayLabel(oscTitle: "claude", procName: "node", shellName: "zsh"),
            "claude"
        )
    }

    /// An empty OSC title (cleared with `ESC ] 2 ; ST`, surfaced as nil) reverts
    /// the label to the foreground process name.
    func testEmptyOSCRevertsToProcName() {
        XCTAssertEqual(
            TermTitle.displayLabel(oscTitle: nil, procName: "vim", shellName: "zsh"),
            "vim"
        )
    }

    /// No OSC title and no process name yet falls back to the shell basename.
    func testNilOSCNilProcFallsBackToShell() {
        XCTAssertEqual(
            TermTitle.displayLabel(oscTitle: nil, procName: nil, shellName: "zsh"),
            "zsh"
        )
    }

    /// An empty process name (the daemon's idle signal) also falls back to shell.
    func testEmptyProcFallsBackToShell() {
        XCTAssertEqual(
            TermTitle.displayLabel(oscTitle: nil, procName: "", shellName: "fish"),
            "fish"
        )
    }

    /// The OSC title wins even when there is no process name yet — a program can
    /// set a title before the daemon's first `term_proc`.
    func testOSCTitleWinsWithNoProc() {
        XCTAssertEqual(
            TermTitle.displayLabel(oscTitle: "build", procName: nil, shellName: "zsh"),
            "build"
        )
    }

    // MARK: isActive

    func testIsActiveGrid() {
        XCTAssertFalse(TermTitle.isActive(oscTitle: nil))
        XCTAssertFalse(TermTitle.isActive(oscTitle: ""))
        XCTAssertTrue(TermTitle.isActive(oscTitle: "anything"))
    }

    // MARK: isLive

    /// A program that set its own OSC title reads as live (agent-active), even
    /// when the foreground process is the bare shell.
    func testOSCTitleCountsAsLive() {
        XCTAssertTrue(TermTitle.isLive(oscTitle: "claude", procName: "zsh", shellName: "zsh"))
    }

    /// Without an OSC title, live falls back to the process heuristic: a
    /// non-shell foreground process is live, the bare shell is idle.
    func testProcHeuristicWhenNoOSC() {
        XCTAssertTrue(TermTitle.isLive(oscTitle: nil, procName: "node", shellName: "zsh"))
        XCTAssertFalse(TermTitle.isLive(oscTitle: nil, procName: "zsh", shellName: "zsh"))
        XCTAssertFalse(TermTitle.isLive(oscTitle: nil, procName: nil, shellName: "zsh"))
        XCTAssertFalse(TermTitle.isLive(oscTitle: nil, procName: "", shellName: "zsh"))
    }

    // MARK: precedence interaction (mirrors the AppController plumbing)

    /// A `term_proc` update does NOT override an active OSC title: with `oscTitle`
    /// set, the displayed label stays the OSC title regardless of which process
    /// name arrives — but the process name is still tracked, so clearing the OSC
    /// title later reverts to it.
    func testProcUpdateDoesNotOverrideActiveOSC() {
        let osc = "claude"
        // term_proc says "node" — label stays the OSC title.
        XCTAssertEqual(TermTitle.displayLabel(oscTitle: osc, procName: "node", shellName: "zsh"), "claude")
        // Then the program clears its title (osc -> nil): revert to the tracked proc.
        XCTAssertEqual(TermTitle.displayLabel(oscTitle: nil, procName: "node", shellName: "zsh"), "node")
    }
}
