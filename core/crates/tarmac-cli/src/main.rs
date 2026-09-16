use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tarmac_protocol::{self as proto, Msg, frame};

mod skill;


// The `dev` family is a debug-build affordance, so a release binary does not
// document it: `README.md` and `SKILL.md` leave it out for the same reason, and
// `--help` is at least as user-facing as either. A release `tarmac dev` still
// exits 1 with DEV_UNAVAILABLE — the verb is recognised, it is just not
// advertised to someone who can never run it.
#[cfg(debug_assertions)]
const DEV_SOCKET: &str = " The dev driver's socket sits beside it as\ntarmac-dev.sock; override with TARMAC_DEV_SOCKET.";
#[cfg(not(debug_assertions))]
const DEV_SOCKET: &str = "";

#[cfg(debug_assertions)]
const DEV_USAGE: &str = "    tarmac dev <verb>       drive and inspect the running app (dev builds only)\n";
#[cfg(not(debug_assertions))]
const DEV_USAGE: &str = "";

#[cfg(debug_assertions)]
const DEV_HELP: &str = "`tarmac dev` talks to the app, not the daemon, over its own socket
(TARMAC_DEV_SOCKET). It exists so an agent or a script can drive and read the
cockpit without a keyboard, and it is available in dev builds only — a release
binary exits 1 with \\\"driver unavailable in release builds\\\".

    tarmac dev snapshot [--until <expr>] [--timeout <ms>]
    tarmac dev zoom <z>
    tarmac dev resize <card> <w>x<h>
    tarmac dev focus <card>|board
    tarmac dev type <card> \\\"<text>\\\"
    tarmac dev key <card> \\\"<combo>\\\"

<card> is a terminal's term id or a doc's absolute path. snapshot prints JSON on
stdout; every other verb prints a small JSON object describing what it observed.
A failing verb prints the app's JSON error on stderr and exits 1.

Three things `dev key` cannot do, by design rather than by omission:
  - ⌘C and ⌘V cannot be driven. They rely on WebKit's native Edit-menu action,
    which an untrusted dispatched event never triggers.
  - A bare printable character is refused; use `tarmac dev type` for text.
    xterm stands aside for such a key, so dispatching one would send nothing.
  - `focus` and `key` go through the real mouse and key paths, so a program with
    mouse reporting on (Claude Code, vim) also receives a button-press report
    when a card is focused.

";
#[cfg(not(debug_assertions))]
const DEV_HELP: &str = "";

const HELP_HEAD_FMT: &str = "\
tarmac — agent cockpit CLI

USAGE:
    tarmac open <path>      register a file with the running tarmac app
    tarmac --version        report the cli, daemon, and app versions
    tarmac skill            print the agent-facing Tarmac guide
    tarmac skill install    install that guide as a SKILL.md for coding agents
{DEV_USAGE}    tarmac --help           show this help

`tarmac open` is fire-and-forget: anything (you, an agent, a Makefile, a git
hook) can run it to surface a doc in the cockpit. The path is canonicalized
and must point to an existing file.

{DEV_HELP}`tarmac skill` never talks to the daemon. `install` writes one SKILL.md per
target — claude-code (~/.claude/skills) and codex (~/.agents/skills) — and
accepts:
";

const HELP_TAIL_FMT: &str = "
The daemon socket defaults to ~/Library/Application Support/tarmac/tarmacd.sock
(release builds) or ~/Library/Application Support/tarmac/dev/tarmacd.sock (dev
builds); override with TARMAC_SOCKET.{DEV_SOCKET}

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

// Compiled out of release builds entirely (issue #166): the driver is dev-only
// machinery, and the same `cfg!(debug_assertions)` predicate feeds the audited
// channel mapping below, so availability and channel cannot disagree.
#[cfg(debug_assertions)]
mod dev;

const DEV_UNAVAILABLE: &str = "driver unavailable in release builds";

fn dev_unavailable() -> i32 {
    eprintln!("tarmac: {DEV_UNAVAILABLE}");
    1
}

/// Without the release arm the verb falls through to the unknown-command path
/// below and exits 2 with the wrong message; the contract is exit 1 with
/// `DEV_UNAVAILABLE`.
#[cfg(debug_assertions)]
fn dev_dispatch(args: &[String]) -> i32 {
    dev::run(args)
}

#[cfg(not(debug_assertions))]
fn dev_dispatch(_args: &[String]) -> i32 {
    dev_unavailable()
}

/// The usage banner, with the dev-only sections present or absent per build.
fn help_head() -> String {
    HELP_HEAD_FMT.replace("{DEV_USAGE}", DEV_USAGE).replace("{DEV_HELP}", DEV_HELP)
}

fn help_tail() -> String {
    HELP_TAIL_FMT.replace("{DEV_SOCKET}", DEV_SOCKET)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("-h") | Some("--help") | Some("help") => {
            print!("{}{}{}", help_head(), skill::USAGE, help_tail());
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
        Some("dev") => std::process::exit(dev_dispatch(&args[1..])),
        Some("skill") => std::process::exit(skill::run(&args[1..])),
        Some("open") => {}
        Some(other) => {
            eprintln!("tarmac: unknown command '{other}' (see tarmac --help)");
            std::process::exit(2);
        }
        None => {
            eprint!("{}{}{}", help_head(), skill::USAGE, help_tail());
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
