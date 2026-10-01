import Foundation

/// Pure per-channel daemon-socket derivation (spec 2606.0003). The build
/// configuration IS the channel: a DEBUG build resolves the socket under a
/// `dev/` subdir, a release build keeps the byte-for-byte legacy flat path
/// (zero migration, no orphaned boards). Kept in TarmacKit — away from
/// AppKit/Foundation I/O — so the rules are table-driven unit-tested;
/// `DaemonClient.resolveSocketPath()` is the thin impure shell (the env read
/// plus the one `#if DEBUG` → `Channel` line). Mirrors `DaemonLaunch`'s
/// enum-of-pure-static-funcs shape and the Rust `tarmac_protocol` resolver
/// across the language boundary — the `dev` literal is duplicated only here,
/// pinned by S2/S5.
public enum ChannelPaths {
    /// Build channel. `.release` is the shipped, signed bundle; `.dev` is any
    /// debug build (`#if DEBUG`).
    public enum Channel { case release, dev }

    /// Resolve the daemon socket path. PURE — no env, no disk.
    /// - `override`: the `TARMAC_SOCKET` value (`nil` if unset). Wins VERBATIM
    ///   iff non-nil AND `!isEmpty` (no trimming) — matching today's
    ///   `resolveSocketPath` `!p.isEmpty`, and unified with Rust (empty == unset,
    ///   spec S9).
    /// - `home`: `NSHomeDirectory()`.
    /// - `channel`: `.dev` for `#if DEBUG` builds, `.release` otherwise.
    ///
    /// Default (no override) = `home` + `/Library/Application Support/tarmac`
    /// + (`channel == .dev` ? `/dev` : "") + `/tarmacd.sock`. `.release`
    /// therefore returns today's flat path BYTE-FOR-BYTE (spec S1); `.dev`
    /// inserts exactly the `/dev` segment (S2/S5).
    public static func socketPath(override: String?, home: String, channel: Channel) -> String {
        if let override, !override.isEmpty { return override }
        let base = home + "/Library/Application Support/tarmac"
        let dir = channel == .dev ? base + "/dev" : base
        return dir + "/tarmacd.sock"
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
