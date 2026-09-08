use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tarmac_protocol::{self as proto, Msg, frame};

mod skill;

const HELP_HEAD: &str = "\
tarmac — agent cockpit CLI

USAGE:
    tarmac open <path>      register a file with the running tarmac app
    tarmac --version        report the cli, daemon, and app versions
    tarmac skill            print the agent-facing Tarmac guide
    tarmac skill install    install that guide as a SKILL.md for coding agents
    tarmac --help           show this help

`tarmac open` is fire-and-forget: anything (you, an agent, a Makefile, a git
hook) can run it to surface a doc in the cockpit. The path is canonicalized
and must point to an existing file.

`tarmac skill` never talks to the daemon. `install` writes one SKILL.md per
target — claude-code (~/.claude/skills) and codex (~/.agents/skills) — and
accepts:
";

const HELP_TAIL: &str = "
The daemon socket defaults to ~/Library/Application Support/tarmac/tarmacd.sock
(release builds) or ~/Library/Application Support/tarmac/dev/tarmacd.sock (dev
builds); override with TARMAC_SOCKET.

`tarmac --version` reports three versions that drift independently — this cli
binary, the running daemon, and the app connected to that daemon — plus the
channel and socket it resolved, so a shadowing dev build is self-evident. It
exits 0 whether or not a daemon is running.

EXIT STATUS:
    0  success; also `tarmac --version` with no daemon running
    1  the daemon rejected the open, no daemon is running, or an install failed
    2  usage error
";

/// The ONE audited build-config → Channel mapping for the CLI (spec 2606.0003):
/// a debug build is the `dev` channel, a release build `release`. The shipped
/// cask CLI is a release build; a contributor's `cargo build` CLI is `dev`.
fn current_channel() -> proto::Channel {
    if cfg!(debug_assertions) {
        proto::Channel::Dev
    } else {
        proto::Channel::Release
    }
}

/// An env override, where an empty value means unset — the convention
/// `tarmac-protocol`'s path resolvers already follow.
pub(crate) fn env_override(name: &str) -> Option<std::ffi::OsString> {
    std::env::var_os(name).filter(|v| !v.is_empty())
}

fn socket_path() -> PathBuf {
    let over = env_override("TARMAC_SOCKET");
    let home = std::env::var_os("HOME").unwrap_or_else(|| std::ffi::OsString::from("/"));
    proto::resolve_socket_path(over, &home, current_channel())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("-h") | Some("--help") | Some("help") => {
            print!("{HELP_HEAD}{}{HELP_TAIL}", skill::USAGE);
            std::process::exit(0);
        }
        Some("--version") => {
            if args.len() != 1 {
                eprintln!("tarmac: usage: tarmac --version");
                std::process::exit(2);
            }
            print!("{}", version_report(&socket_path()));
            std::process::exit(0);
        }
        Some("skill") => std::process::exit(skill::run(&args[1..])),
        Some("open") => {}
        Some(other) => {
            eprintln!("tarmac: unknown command '{other}' (see tarmac --help)");
            std::process::exit(2);
        }
        None => {
            eprint!("{HELP_HEAD}{}{HELP_TAIL}", skill::USAGE);
            std::process::exit(2);
        }
    }
    if args.len() != 2 {
        eprintln!("tarmac: usage: tarmac open <path>");
        std::process::exit(2);
    }
    match open(&args[1]) {
        Ok(line) => println!("{line}"),
        Err(line) => {
            eprintln!("tarmac: {line}");
            std::process::exit(1);
        }
    }
}

fn send(stream: &mut UnixStream, msg: &Msg) -> Result<(), String> {
    let payload = proto::encode(msg).map_err(|e| format!("encode failed: {e}"))?;
    frame::write_sync(stream, &payload).map_err(|e| format!("daemon connection lost: {e}"))
}

fn recv(stream: &mut UnixStream) -> Result<Msg, String> {
    let payload =
        frame::read_sync(stream).map_err(|e| format!("daemon connection lost: {e}"))?;
    proto::decode(&payload).map_err(|e| format!("bad frame from daemon: {e}"))
}

/// The `hello_ok` fields. `open` only needs the reply to have arrived;
/// `--version` renders every one of them.
struct DaemonInfo {
    daemon_version: Option<String>,
    daemon_pid: Option<u32>,
    app_version: Option<String>,
    app_connected: Option<bool>,
}

/// Why no `hello_ok` came back. The split is load-bearing for `--version`: only
/// a failed `connect` is evidence that nothing is running. Everything else —
/// including a path we refused to dial — leaves the daemon's state unobserved.
enum NoHandshake {
    NoDaemon,
    Reason(String),
}

/// Connect and complete the `hello`/`hello_ok` exchange, returning the live
/// stream so `open` can keep using it.
fn handshake(sock: &Path) -> Result<(UnixStream, DaemonInfo), NoHandshake> {
    proto::check_socket_path_len(sock).map_err(NoHandshake::Reason)?;
    let mut stream = UnixStream::connect(sock).map_err(|_| NoHandshake::NoDaemon)?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    send(&mut stream, &Msg::Hello {
        role: "cli".into(),
        v: proto::PROTOCOL_VERSION,
        // Only the app names itself here; a cli client is not an app.
        app_version: None,
    })
    .map_err(NoHandshake::Reason)?;
    match recv(&mut stream).map_err(NoHandshake::Reason)? {
        Msg::HelloOk { daemon_version, daemon_pid, app_version, app_connected, .. } => Ok((
            stream,
            DaemonInfo { daemon_version, daemon_pid, app_version, app_connected },
        )),
        Msg::Err { msg } => Err(NoHandshake::Reason(format!("daemon rejected handshake: {msg}"))),
        other => Err(NoHandshake::Reason(format!("unexpected handshake reply: {other:?}"))),
    }
}

/// The five-line report. Every value states what was observed, never what was
/// inferred: an absent app is only ever reported when the daemon said so.
fn version_report(sock: &Path) -> String {
    let (daemon, app) = match handshake(sock) {
        Ok((_, info)) => (daemon_line(&info), app_line(&info)),
        Err(NoHandshake::NoDaemon) => ("not running".into(), "unknown (no daemon)".into()),
        Err(NoHandshake::Reason(why)) => {
            (format!("unreachable ({why})"), "unknown (daemon unreachable)".into())
        }
    };
    [
        ("cli", env!("CARGO_PKG_VERSION").to_string()),
        ("daemon", daemon),
        ("app", app),
        ("channel", proto::channel_label(current_channel()).to_string()),
        ("socket", sock.display().to_string()),
    ]
    .iter()
    // Flattening newlines keeps the report five lines even when a daemon's
    // rejection message spans several.
    .map(|(label, value)| format!("{label:<8} {}\n", value.replace(['\n', '\r'], " ")))
    .collect()
}

fn daemon_line(info: &DaemonInfo) -> String {
    match (&info.daemon_version, info.daemon_pid) {
        (Some(v), Some(pid)) => format!("{v} (pid {pid})"),
        (Some(v), None) => v.clone(),
        (None, _) => "connected (version not reported)".into(),
    }
}

fn app_line(info: &DaemonInfo) -> String {
    match (&info.app_version, info.app_connected) {
        (Some(v), _) => format!("{v} (running)"),
        (None, Some(true)) => "connected (version not reported)".into(),
        (None, Some(false)) => "not connected".into(),
        (None, None) => "unknown (daemon predates this key)".into(),
    }
}

fn open(raw_path: &str) -> Result<String, String> {
    let canon = std::fs::canonicalize(raw_path)
        .map_err(|e| format!("cannot open {raw_path}: {e}"))?;
    let meta = std::fs::metadata(&canon)
        .map_err(|e| format!("cannot stat {}: {e}", canon.display()))?;
    if !meta.is_file() {
        return Err(format!("not a regular file: {}", canon.display()));
    }

    let sock = socket_path();
    let (mut stream, _) = handshake(&sock).map_err(|e| match e {
        NoHandshake::NoDaemon => format!(
            "no tarmac daemon running ({} channel, socket: {})",
            proto::channel_label(current_channel()),
            sock.display()
        ),
        NoHandshake::Reason(why) => why,
    })?;

    // v4 Phase 3 provenance: if this CLI is running inside a tarmac pty, the
    // daemon set TARMAC_TERM_ID in its env — attribute the open to that term.
    let term_id = std::env::var("TARMAC_TERM_ID").ok().filter(|s| !s.is_empty());
    // board_id stays None: the daemon resolves the target board from term_id
    // (the term's owning board), falling back to the active board.
    send(&mut stream, &Msg::Open { path: canon.to_string_lossy().into_owned(), term_id, board_id: None })?;
    loop {
        match recv(&mut stream)? {
            Msg::Ack => return Ok(format!("opened {}", canon.display())),
            Msg::Err { msg } => return Err(msg),
            _ => continue, // tolerate stray frames
        }
    }
}
