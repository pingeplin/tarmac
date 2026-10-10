use std::ffi::OsString;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tarmac_protocol::{self as proto, Msg, frame};

mod help;
mod skill;

/// The one build-config to channel mapping: a debug build is `dev`, a release
/// build `release`.
fn current_channel() -> proto::Channel {
    if cfg!(debug_assertions) {
        proto::Channel::Dev
    } else {
        proto::Channel::Release
    }
}

/// An env override, where an empty value means unset — the convention
/// `tarmac-protocol`'s path resolvers already follow.
pub(crate) fn env_override(name: &str) -> Option<OsString> {
    std::env::var_os(name).filter(|v| !v.is_empty())
}

pub(crate) fn home_or_root() -> OsString {
    std::env::var_os("HOME").unwrap_or_else(|| "/".into())
}

fn socket_path() -> PathBuf {
    proto::resolve_socket_path(env_override("TARMAC_SOCKET"), &home_or_root(), current_channel())
}

// Compiled out of release builds; the same `cfg!(debug_assertions)` feeds
// `current_channel`, so availability and channel cannot disagree.
#[cfg(debug_assertions)]
mod dev;

#[cfg(debug_assertions)]
fn dev_dispatch(args: &[String]) -> i32 {
    dev::run(args)
}

// Without this arm `dev` would reach the unknown-command path and exit 2.
#[cfg(not(debug_assertions))]
fn dev_dispatch(_args: &[String]) -> i32 {
    eprintln!("tarmac: driver unavailable in release builds");
    1
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(run(&args));
}

fn run(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        Some("-h" | "--help" | "help") => {
            print!("{}", help::text());
            0
        }
        Some("--version") if args.len() == 1 => {
            print!("{}", version_report(&socket_path()));
            0
        }
        Some("--version") => {
            eprintln!("tarmac: usage: tarmac --version");
            2
        }
        Some("dev") => dev_dispatch(&args[1..]),
        Some("skill") => skill::run(&args[1..]),
        Some("open") => match &args[1..] {
            [path] => match open(path) {
                Ok(line) => {
                    println!("{line}");
                    0
                }
                Err(line) => {
                    eprintln!("tarmac: {line}");
                    1
                }
            },
            _ => {
                eprintln!("tarmac: usage: tarmac open <path>");
                2
            }
        },
        Some(other) => {
            eprintln!("tarmac: unknown command '{other}' (see tarmac --help)");
            2
        }
        None => {
            eprint!("{}", help::text());
            2
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

/// The `hello_ok` fields; `open` needs only the reply, `--version` renders all.
struct DaemonInfo {
    daemon_version: Option<String>,
    daemon_pid: Option<u32>,
    app_version: Option<String>,
    app_connected: Option<bool>,
}

/// Why no `hello_ok` came back. Only a failed `connect` is evidence that nothing
/// is running; anything else, including a path we refused to dial, leaves the
/// daemon's state unobserved.
enum NoHandshake {
    NoDaemon,
    Reason(String),
}

/// Returns the live stream so `open` can keep using it.
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

/// The five-line report. Every value is observed, never inferred: an absent app
/// is reported only when the daemon said so.
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
    // Flattening newlines keeps the report five lines when a rejection spans several.
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

    let term_id = std::env::var("TARMAC_TERM_ID").ok().filter(|s| !s.is_empty());
    // board_id stays None: the daemon resolves the board from term_id, falling
    // back to the active one.
    send(&mut stream, &Msg::Open { path: canon.to_string_lossy().into_owned(), term_id, board_id: None })?;
    loop {
        match recv(&mut stream)? {
            Msg::Ack => return Ok(format!("opened {}", canon.display())),
            Msg::Err { msg } => return Err(msg),
            _ => continue,
        }
    }
}
