import XCTest
@testable import TarmacKit

/// 2606.0003: per-channel daemon socket path derivation — the Swift mirror of
/// the Rust `tarmac_protocol` resolver. Pure, table-driven, S-numbers in
/// comments. The impure shell (`DaemonClient.resolveSocketPath`, the
/// `#if DEBUG` → Channel mapping) is not unit-tested.
final class ChannelPathsTests: XCTestCase {
    private let home = "/Users/eplin"

    // MARK: - socketPath

    /// S1/S2/S3/S4/S9: the resolution grid. Release == today's flat path
    /// byte-for-byte (S1); dev inserts exactly `/dev` (S2); an explicit override
    /// wins verbatim in BOTH channels (S3/S4); an empty override is treated as
    /// unset and falls through to the channel default (S9).
    func testSocketPathGrid() {
        let cases: [(override: String?, channel: ChannelPaths.Channel, expected: String)] = [
            // S1: release == today's flat path (backward compat, zero migration).
            (nil, .release, "/Users/eplin/Library/Application Support/tarmac/tarmacd.sock"),
            // S2: dev inserts the `dev/` segment.
            (nil, .dev, "/Users/eplin/Library/Application Support/tarmac/dev/tarmacd.sock"),
            // S3: override wins verbatim in the release channel.
            ("/tmp/x.sock", .release, "/tmp/x.sock"),
            // S4: override wins verbatim EVEN in dev — the channel never shadows it.
            ("/tmp/x.sock", .dev, "/tmp/x.sock"),
            // S9: empty override == unset → falls through to the dev default.
            ("", .dev, "/Users/eplin/Library/Application Support/tarmac/dev/tarmacd.sock"),
        ]
        for c in cases {
            XCTAssertEqual(
                ChannelPaths.socketPath(override: c.override, home: home, channel: c.channel),
                c.expected,
                "socketPath(override: \(c.override.map { "\"\($0)\"" } ?? "nil"), channel: \(c.channel))"
            )
        }
    }

    /// S5: dev differs from release ONLY by the inserted `/dev` segment,
    /// immediately before `/tarmacd.sock`, with nothing else moved. A renamed
    /// marker or a misplaced insert breaks this.
    func testDevDiffersFromReleaseOnlyBySegment() {
        let release = ChannelPaths.socketPath(override: nil, home: home, channel: .release)
        let dev = ChannelPaths.socketPath(override: nil, home: home, channel: .dev)
        XCTAssertEqual(
            dev,
            release.replacingOccurrences(of: "/tarmacd.sock", with: "/dev/tarmacd.sock")
        )
    }

    // MARK: - sockaddr_un byte budget (S8 / S8b)

    /// S8: the dev default appends a fixed 52-byte suffix to `home`. So a
    /// 51-byte home yields a 103-byte socket (accepted at the `len < 104` cap)
    /// and a 52-byte home yields 104 (rejected). Assert BOTH the exact byte
    /// count (`utf8.count`) and the accept/reject outcome at the same predicate
    /// `connectOnce` enforces (`DaemonClient.fitsUnixSocketPath`).
    func testDevSocketByteBoundary() {
        let home51 = "/" + String(repeating: "a", count: 50) // 51 bytes
        XCTAssertEqual(home51.utf8.count, 51)
        let s51 = ChannelPaths.socketPath(override: nil, home: home51, channel: .dev)
        XCTAssertEqual(s51.utf8.count, 103)
        XCTAssertTrue(DaemonClient.fitsUnixSocketPath(s51), "103 bytes is accepted (len < 104)")

        let home52 = "/" + String(repeating: "a", count: 51) // 52 bytes
        XCTAssertEqual(home52.utf8.count, 52)
        let s52 = ChannelPaths.socketPath(override: nil, home: home52, channel: .dev)
        XCTAssertEqual(s52.utf8.count, 104)
        XCTAssertFalse(DaemonClient.fitsUnixSocketPath(s52), "104 bytes is rejected (104 < 104 is false)")
    }

    /// S8b: the `make run` per-worktree path inserts `dev/wt-XXXXXXXX/` (16
    /// bytes) for plain `dev/` (4) — a fixed 64-byte suffix. It rides the
    /// verbatim override, so `socketPath` returns it UNCHANGED (S3/S4); pin the
    /// constructed string's byte counts (103 at a 39-byte home, 104 at 40) so a
    /// drift in the `wt-` prefix or the 8-hex width is caught, and assert
    /// accept/reject at the same predicate `connectOnce` uses.
    func testPerWorktreeDevSocketByteBoundary() {
        func perWorktree(_ home: String) -> String {
            home + "/Library/Application Support/tarmac/dev/wt-0123abcd/tarmacd.sock"
        }
        let home39 = "/" + String(repeating: "a", count: 38) // 39 bytes
        XCTAssertEqual(home39.utf8.count, 39)
        let p39 = perWorktree(home39)
        XCTAssertEqual(p39.utf8.count, 103)
        XCTAssertTrue(DaemonClient.fitsUnixSocketPath(p39))
        // Override wins verbatim (S3/S4): the resolver returns it unchanged.
        XCTAssertEqual(ChannelPaths.socketPath(override: p39, home: "/ignored", channel: .dev), p39)

        let home40 = "/" + String(repeating: "a", count: 39) // 40 bytes
        XCTAssertEqual(home40.utf8.count, 40)
        let p40 = perWorktree(home40)
        XCTAssertEqual(p40.utf8.count, 104)
        XCTAssertFalse(DaemonClient.fitsUnixSocketPath(p40))
    }

    // MARK: - channelLabel

    /// S10: the channel label maps both arms (a swapped or constant label fails).
    func testChannelLabel() {
        XCTAssertEqual(ChannelPaths.channelLabel(.release), "release")
        XCTAssertEqual(ChannelPaths.channelLabel(.dev), "dev")
    }
}
