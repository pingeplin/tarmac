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

    // MARK: - channelDir

    /// The one place the `dev` segment is spelled, shared by all three resolvers.
    func testChannelDir() {
        XCTAssertEqual(
            ChannelPaths.channelDir(home: home, channel: .release),
            "/Users/eplin/Library/Application Support/tarmac"
        )
        XCTAssertEqual(
            ChannelPaths.channelDir(home: home, channel: .dev),
            "/Users/eplin/Library/Application Support/tarmac/dev"
        )
    }

    /// Rust joins with `Path::join`, not string concatenation, so the daemon and
    /// CLI's `HOME`-unset fallback of `/` yields one slash, a trailing slash is
    /// not doubled, and an empty home stays relative. Values are what
    /// `resolve_socket_path` returns for each home.
    func testHomeJoinsLikeARustPath() {
        let cases: [(home: String, expected: String)] = [
            ("/", "/Library/Application Support/tarmac/dev/tarmacd.sock"),
            ("/Users/x/", "/Users/x/Library/Application Support/tarmac/dev/tarmacd.sock"),
            ("", "Library/Application Support/tarmac/dev/tarmacd.sock"),
            ("rel", "rel/Library/Application Support/tarmac/dev/tarmacd.sock"),
        ]
        for c in cases {
            XCTAssertEqual(
                ChannelPaths.socketPath(override: nil, home: c.home, channel: .dev),
                c.expected,
                "home: \"\(c.home)\""
            )
        }
    }

    // MARK: - statePath

    /// S6/S7/S9 for the state resolver — the Rust `resolve_state_path_cases` grid.
    func testStatePathGrid() {
        let cases: [(override: String?, channel: ChannelPaths.Channel, expected: String)] = [
            // S6: release == the legacy flat path.
            (nil, .release, "/Users/eplin/Library/Application Support/tarmac/state.json"),
            // S7: dev carries the SAME `dev/` segment as the socket.
            (nil, .dev, "/Users/eplin/Library/Application Support/tarmac/dev/state.json"),
            ("/tmp/s.json", .release, "/tmp/s.json"),
            ("/tmp/s.json", .dev, "/tmp/s.json"),
            // S9: empty override == unset.
            ("", .dev, "/Users/eplin/Library/Application Support/tarmac/dev/state.json"),
        ]
        for c in cases {
            XCTAssertEqual(
                ChannelPaths.statePath(override: c.override, home: home, channel: c.channel),
                c.expected,
                "statePath(override: \(c.override.map { "\"\($0)\"" } ?? "nil"), channel: \(c.channel))"
            )
        }
    }

    // MARK: - devSocketPath

    /// S50/S51: the QA driver's socket per channel; `TARMAC_DEV_SOCKET` wins
    /// verbatim in both, and empty means unset.
    func testDevSocketPathGrid() {
        let cases: [(override: String?, channel: ChannelPaths.Channel, expected: String)] = [
            (nil, .dev, "/Users/eplin/Library/Application Support/tarmac/dev/tarmac-dev.sock"),
            (nil, .release, "/Users/eplin/Library/Application Support/tarmac/tarmac-dev.sock"),
            ("/tmp/x.sock", .release, "/tmp/x.sock"),
            ("/tmp/x.sock", .dev, "/tmp/x.sock"),
            ("", .dev, "/Users/eplin/Library/Application Support/tarmac/dev/tarmac-dev.sock"),
            ("", .release, "/Users/eplin/Library/Application Support/tarmac/tarmac-dev.sock"),
        ]
        for c in cases {
            XCTAssertEqual(
                ChannelPaths.devSocketPath(override: c.override, home: home, channel: c.channel),
                c.expected,
                "devSocketPath(override: \(c.override.map { "\"\($0)\"" } ?? "nil"), channel: \(c.channel))"
            )
        }
    }

    /// S7/S52 by construction: the three files share the per-channel directory,
    /// so a dev app can never meet a dev socket beside release state.
    func testSocketStateAndDevSocketShareTheChannelDir() {
        for channel in [ChannelPaths.Channel.release, .dev] {
            let dir = ChannelPaths.channelDir(home: home, channel: channel)
            XCTAssertEqual(ChannelPaths.socketPath(override: nil, home: home, channel: channel), dir + "/tarmacd.sock")
            XCTAssertEqual(ChannelPaths.statePath(override: nil, home: home, channel: channel), dir + "/state.json")
            XCTAssertEqual(
                ChannelPaths.devSocketPath(override: nil, home: home, channel: channel),
                dir + "/tarmac-dev.sock"
            )
        }
    }

    // MARK: - home

    /// The daemon and CLI read `HOME` and fall back to `/`; the app must feed its
    /// resolvers the same value or it looks for a daemon somewhere else.
    func testHomeComesFromTheEnvironment() {
        XCTAssertEqual(ChannelPaths.home(env: ["HOME": "/Users/x"]), "/Users/x")
        XCTAssertEqual(ChannelPaths.home(env: [:]), "/")
        XCTAssertEqual(ChannelPaths.home(env: ["HOME": ""]), "")
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

    // MARK: - configDir (spec 2610.0009)

    /// 2610.0009 S1: the override wins verbatim in both channels; an absolute
    /// `XDG_CONFIG_HOME` is the base, and an empty or a relative one is not;
    /// a debug build adds `/dev`, but never to an override.
    func testConfigDirGrid() {
        typealias Case = (override: String?, xdg: String?, home: String, channel: ChannelPaths.Channel, expected: String)
        let cases: [Case] = [
            (nil, nil, "/Users/u", .release, "/Users/u/.config/tarmac"),
            (nil, nil, "/Users/u", .dev, "/Users/u/.config/tarmac/dev"),
            (nil, "/x/cfg", "/Users/u", .release, "/x/cfg/tarmac"),
            (nil, "/x/cfg/", "/Users/u", .dev, "/x/cfg/tarmac/dev"),
            (nil, "", "/Users/u", .release, "/Users/u/.config/tarmac"),
            (nil, "cfg", "/Users/u", .release, "/Users/u/.config/tarmac"),
            ("", nil, "/", .release, "/.config/tarmac"),
            ("/w/.dev/config", "/x/cfg", "/Users/u", .release, "/w/.dev/config"),
            ("/w/.dev/config", "/x/cfg", "/Users/u", .dev, "/w/.dev/config"),
            (nil, nil, "", .release, ".config/tarmac"),
        ]
        for c in cases {
            XCTAssertEqual(
                ChannelPaths.configDir(override: c.override, xdgConfigHome: c.xdg, home: c.home, channel: c.channel),
                c.expected,
                "configDir(override: \(c.override ?? "nil"), xdg: \(c.xdg ?? "nil"), home: \(c.home), \(c.channel))"
            )
        }
    }

    /// 2610.0009 S2
    func testThemesDirIsTheConfigDirAndThenThemes() {
        XCTAssertEqual(ChannelPaths.themesDir(configDir: "/a/b"), "/a/b/themes")
        XCTAssertEqual(ChannelPaths.themesDir(configDir: "/a/b/"), "/a/b/themes")
    }

    // MARK: - prefsDir (issue #220)

    /// A scratch launch pins the socket and not the config directory. Its
    /// config directory is then not its own, so its preferences stay beside
    /// the socket. An empty value pins nothing.
    func testPrefsDirGrid() {
        typealias Case = (configOverride: String?, socketOverride: String?, expected: String)
        let cases: [Case] = [
            (nil, nil, "/c/tarmac"),
            ("/c/tarmac", "/s/tarmacd.sock", "/c/tarmac"),
            ("/c/tarmac", nil, "/c/tarmac"),
            (nil, "/s/tarmacd.sock", "/s"),
            (nil, "tarmacd.sock", ""),
            ("", "/s/tarmacd.sock", "/s"),
            (nil, "", "/c/tarmac"),
            ("", "", "/c/tarmac"),
        ]
        for c in cases {
            XCTAssertEqual(
                ChannelPaths.prefsDir(
                    configDir: "/c/tarmac", configOverride: c.configOverride, socketOverride: c.socketOverride
                ),
                c.expected,
                "prefsDir(configOverride: \(c.configOverride ?? "nil"), socketOverride: \(c.socketOverride ?? "nil"))"
            )
        }
    }
}
