import Foundation

/// Pure per-channel path derivation (spec 2606.0003) — the Swift twin of
/// `tarmac_protocol`'s `channel_dir` / `resolve_socket_path` /
/// `resolve_state_path` / `dev::resolve_dev_socket_path`. The build
/// configuration IS the channel: a debug build resolves under a `dev/` subdir, a
/// release build keeps the byte-for-byte legacy flat path (zero migration, no
/// orphaned boards). Nothing here reads the environment or the disk, so the
/// rules are table-driven unit-tested; the caller supplies the override, the
/// home directory and the channel. The `dev` literal is duplicated only here
/// across the language boundary, pinned by S2/S5.
public enum ChannelPaths {
    /// Build channel. `.release` is the shipped, signed bundle; `.dev` is any
    /// debug build. Rust maps `cfg!(debug_assertions)` to it at one audited line
    /// per binary; the Swift app's line is `Channel.build`.
    public enum Channel: Sendable {
        case release, dev

        /// The ONE audited build-config → channel mapping on the Swift side.
        /// SwiftPM defines `DEBUG` for `-c debug` and not for `-c release`, the
        /// same split as `debug_assertions` in a cargo profile — so a debug app
        /// and a debug daemon meet on the `dev/` socket by default.
        public static var build: Channel {
            #if DEBUG
            return .dev
            #else
            return .release
            #endif
        }
    }

    /// The home directory the resolvers take, read the way `tarmacd` and the
    /// CLI read it: `$HOME` verbatim, `/` when unset. Not `NSHomeDirectory()` —
    /// the app spawns a daemon that inherits this environment, and the two must
    /// derive the same socket from it.
    public static func home(env: [String: String]) -> String {
        env["HOME"] ?? "/"
    }

    /// The per-channel directory every resolver below shares for its default
    /// branch: `home`/Library/Application Support/tarmac` + (`.dev` ⇒ `/dev`).
    /// Joined like a Rust `Path`, so a `home` of `/` or one with a trailing
    /// slash yields a single separator and an empty `home` stays relative.
    public static func channelDir(home: String, channel: Channel) -> String {
        let base = join(home, "Library/Application Support/tarmac")
        return channel == .dev ? join(base, "dev") : base
    }

    /// Tarmac's config directory (spec 2610.0009), where the user's own files
    /// are: `TARMAC_CONFIG_DIR` verbatim iff non-nil AND `!isEmpty`, in both
    /// channels; else `XDG_CONFIG_HOME` when it is absolute (the XDG
    /// specification has an empty or a relative one ignored), else
    /// `home/.config`; then `/tarmac`, and for `.dev` then `/dev`. It has no
    /// Rust twin: only the app reads it.
    public static func configDir(
        override: String?, xdgConfigHome: String?, home: String, channel: Channel
    ) -> String {
        if let override, !override.isEmpty { return override }
        let base = xdgConfigHome.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? join(home, ".config")
        let directory = join(base, "tarmac")
        return channel == .dev ? join(directory, "dev") : directory
    }

    /// The folder of the user's theme files.
    public static func themesDir(configDir: String) -> String {
        join(configDir, "themes")
    }

    private static func join(_ base: String, _ part: String) -> String {
        base + (base.isEmpty || base.hasSuffix("/") ? "" : "/") + part
    }

    /// The daemon socket. `override` is `TARMAC_SOCKET` (`nil` if unset): it wins
    /// VERBATIM iff non-nil AND `!isEmpty` (no trimming; empty == unset, spec
    /// S9), in both channels (S3/S4). Otherwise `channelDir/tarmacd.sock` —
    /// `.release` is today's flat path byte-for-byte (S1), `.dev` inserts
    /// exactly the `/dev` segment (S2/S5).
    public static func socketPath(override: String?, home: String, channel: Channel) -> String {
        resolve(override, home: home, channel: channel, file: "tarmacd.sock")
    }

    /// The daemon's state file — `TARMAC_STATE`, else `channelDir/state.json`,
    /// beside the socket (S6/S7). Only `tarmacd` reads it; the app resolves it to
    /// name the file, never to open it.
    public static func statePath(override: String?, home: String, channel: Channel) -> String {
        resolve(override, home: home, channel: channel, file: "state.json")
    }

    /// The in-app QA driver's socket (issue #166), which the APP binds —
    /// `TARMAC_DEV_SOCKET`, else `channelDir/tarmac-dev.sock` (S50–S52).
    public static func devSocketPath(override: String?, home: String, channel: Channel) -> String {
        resolve(override, home: home, channel: channel, file: "tarmac-dev.sock")
    }

    private static func resolve(_ override: String?, home: String, channel: Channel, file: String) -> String {
        if let override, !override.isEmpty { return override }
        return channelDir(home: home, channel: channel) + "/" + file
    }

    /// Human label for diagnostics: `.release` -> `"release"`, `.dev` -> `"dev"`.
    /// Mirrors Rust `tarmac_protocol::channel_label` (spec S10).
    public static func channelLabel(_ channel: Channel) -> String {
        switch channel {
        case .release: return "release"
        case .dev: return "dev"
        }
    }
}
