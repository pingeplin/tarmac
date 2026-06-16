import XCTest
@testable import TarmacKit

/// 2606.0002: bundled-daemon-path resolution and PTY `PATH` injection.
final class DaemonLaunchTests: XCTestCase {
    private let bundle = URL(fileURLWithPath: "/A/Tarmac.app")
    private var bundledDaemon: String { "/A/Tarmac.app/Contents/MacOS/tarmacd" }

    // MARK: - resolveDaemonPath

    /// S1, S2, S4, S5, S11, S13: the full resolution grid. Columns are the env
    /// value for `TARMAC_DAEMON` (`nil` = key absent) and whether a bundled binary
    /// exists. The explicit override must win VERBATIM and UNCONDITIONALLY — even
    /// with no bundled binary (S1) and even when one exists (S5) — while an absent
    /// or empty override falls through to the bundled path (S2/S4) or `nil` (S11).
    /// S13 pins that "non-empty" is `!isEmpty` with no trimming: a whitespace-only
    /// override is honored verbatim, so it must NOT be confused with the empty case.
    func testResolveDaemonPathGrid() {
        let cases: [(override: String?, exists: Bool, expected: String?)] = [
            ("/dbg/tarmacd", false, "/dbg/tarmacd"),   // S1: override wins with no bundled binary
            (nil, true, "/A/Tarmac.app/Contents/MacOS/tarmacd"), // S2: bundled fallback
            ("", true, "/A/Tarmac.app/Contents/MacOS/tarmacd"),  // S4: empty == unset → bundled
            ("/dbg/tarmacd", true, "/dbg/tarmacd"),    // S5: override beats the bundled path
            (nil, false, nil),                          // S11: neither → nil (caller errors)
            ("   ", true, "   "),                       // S13: whitespace-only counts as set
        ]
        for c in cases {
            var env: [String: String] = [:]
            if let override = c.override { env["TARMAC_DAEMON"] = override }
            XCTAssertEqual(
                DaemonLaunch.resolveDaemonPath(env: env, bundleURL: bundle, bundledBinaryExists: c.exists),
                c.expected,
                "resolveDaemonPath(override: \(c.override.map { "\"\($0)\"" } ?? "nil"), exists: \(c.exists))"
            )
        }
    }

    /// S4-vs-S5 boundary, pinned on its own so the mutation is unmissable: with a
    /// bundled binary present, an EMPTY override falls through to the bundled path
    /// while a NON-empty override is returned verbatim. A `!isEmpty`→`!= nil`
    /// mutation (treating "" as a valid override) flips the first assertion.
    func testEmptyOverrideFallsThroughButSetOverrideWins() {
        XCTAssertEqual(
            DaemonLaunch.resolveDaemonPath(env: ["TARMAC_DAEMON": ""], bundleURL: bundle, bundledBinaryExists: true),
            bundledDaemon
        )
        XCTAssertEqual(
            DaemonLaunch.resolveDaemonPath(env: ["TARMAC_DAEMON": "/x"], bundleURL: bundle, bundledBinaryExists: true),
            "/x"
        )
    }

    /// S2: the derived path is exactly `<bundleURL>/Contents/MacOS/tarmacd`. Guards
    /// a mutation that drops `Contents/`, mislocates `MacOS/`, or renames the binary.
    func testBundledPathShape() {
        XCTAssertEqual(
            DaemonLaunch.resolveDaemonPath(env: [:], bundleURL: bundle, bundledBinaryExists: true),
            bundledDaemon
        )
    }

    // MARK: - injectCLIPath

    /// S3, S6, S7, S8, S9, S12: the injection grid over `(base, cliDir)`.
    /// `nil` base is covered separately in `testInjectNilBase` (the table can't
    /// hold `nil` cleanly alongside `""`).
    func testInjectCLIPathGrid() {
        let cases: [(base: String, cliDir: String, expected: String)] = [
            ("/usr/bin:/bin", "/opt/homebrew/bin", "/opt/homebrew/bin:/usr/bin:/bin"),     // S3: prepend
            ("/usr/bin:/opt/homebrew/bin", "/opt/homebrew/bin", "/usr/bin:/opt/homebrew/bin"), // S6: already present → unchanged
            ("", "/opt/homebrew/bin", "/opt/homebrew/bin"),                                 // S7: empty base
            ("/usr/bin:", "/x", "/x:/usr/bin:"),                                            // S8: trailing empty segment preserved
            ("/opt/homebrew/binfoo", "/opt/homebrew/bin", "/opt/homebrew/bin:/opt/homebrew/binfoo"), // S9: substring is not a segment
            ("/usr/bin:/bin", "", "/usr/bin:/bin"),                                         // S12: empty cliDir → unchanged
        ]
        for c in cases {
            XCTAssertEqual(
                DaemonLaunch.injectCLIPath(base: c.base, cliDir: c.cliDir),
                c.expected,
                "injectCLIPath(base: \"\(c.base)\", cliDir: \"\(c.cliDir)\")"
            )
        }
    }

    /// S7 / S12: a `nil` base yields just `cliDir`, and a `nil` base with an empty
    /// `cliDir` yields `""` — never a stray leading colon.
    func testInjectNilBase() {
        XCTAssertEqual(DaemonLaunch.injectCLIPath(base: nil, cliDir: "/opt/homebrew/bin"), "/opt/homebrew/bin")
        XCTAssertEqual(DaemonLaunch.injectCLIPath(base: nil, cliDir: ""), "")
    }

    /// S6-vs-S9 boundary on its own: presence is decided by whole-segment equality,
    /// not substring containment. `/opt/homebrew/bin` is "present" in
    /// `/usr/bin:/opt/homebrew/bin` (unchanged) but NOT in `/opt/homebrew/binfoo`
    /// (prepended). A `base.contains(cliDir)` mutation collapses the two.
    func testSegmentMatchNotSubstring() {
        XCTAssertEqual(
            DaemonLaunch.injectCLIPath(base: "/usr/bin:/opt/homebrew/bin", cliDir: "/opt/homebrew/bin"),
            "/usr/bin:/opt/homebrew/bin"
        )
        XCTAssertEqual(
            DaemonLaunch.injectCLIPath(base: "/opt/homebrew/binfoo", cliDir: "/opt/homebrew/bin"),
            "/opt/homebrew/bin:/opt/homebrew/binfoo"
        )
    }

    /// S10: idempotency across every branch — applying `injectCLIPath` to its own
    /// output changes nothing. This is the property that the dedup must satisfy;
    /// dropping the segment check makes the prepend branch grow on every call and
    /// breaks the first case here.
    func testInjectCLIPathIdempotent() {
        let inputs: [(base: String, cliDir: String)] = [
            ("/usr/bin:/bin", "/opt/homebrew/bin"),       // prepend branch
            ("/usr/bin:/opt/homebrew/bin", "/opt/homebrew/bin"), // already-present branch
            ("", "/opt/homebrew/bin"),                     // empty-base branch
            ("/opt/homebrew/binfoo", "/opt/homebrew/bin"), // substring branch
            ("/usr/bin:", "/x"),                           // trailing-colon branch
        ]
        for input in inputs {
            let once = DaemonLaunch.injectCLIPath(base: input.base, cliDir: input.cliDir)
            let twice = DaemonLaunch.injectCLIPath(base: once, cliDir: input.cliDir)
            XCTAssertEqual(twice, once, "not idempotent for base \"\(input.base)\", cliDir \"\(input.cliDir)\"")
        }
    }
}
