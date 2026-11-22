use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::Instant;

use tarmac_protocol::{self as proto, Msg};

use daemon::{DAEMON_WAIT, DaemonInfo, NoHandshake, connect, exchange, handshake, not_answered};

mod agents;
mod daemon;
mod events;
#[cfg(test)]
mod fixtures;
mod help;
mod hooks;
mod push;
mod report;
mod resume;
mod settings_file;
mod skill;
mod term;
mod terms;
mod wait;

/// The one build-config to channel mapping: a debug build is `dev`, a release
/// build `release`.
fn current_channel() -> proto::Channel {
    if cfg!(debug_assertions) { proto::Channel::Dev } else { proto::Channel::Release }
}

/// An env override, where an empty value means unset — the convention
/// `tarmac-protocol`'s path resolvers already follow.
pub(crate) fn env_override(name: &str) -> Option<OsString> {
    std::env::var_os(name).filter(|v| !v.is_empty())
}

/// The terminal this process runs in, from `TARMAC_TERM_ID`. A value that is
/// not UTF-8 is no terminal: the daemon gives no such id.
pub(crate) fn calling_term() -> Option<String> {
    term_of(env_override("TARMAC_TERM_ID"))
}

fn term_of(value: Option<OsString>) -> Option<String> {
    value?.into_string().ok()
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
        Some("push") => push::run(&args[1..]),
        Some("report") => report::run(&args[1..]),
        Some("resume") => resume::run(&args[1..]),
        Some("hooks") => hooks::run(&args[1..]),
        Some("terms") => terms::run(&args[1..]),
        Some("term") => term::run(&args[1..]),
        Some("events") => events::run(&args[1..]),
        Some("wait") => wait::run(&args[1..]),
        Some(wait::STAT_HELPER) => wait::stat_helper(&args[1..]),
        Some("open") => {
            if let [path] = &args[1..] {
                match open(path) {
                    Ok(line) => {
                        println!("{line}");
                        0
                    }
                    Err(line) => {
                        eprintln!("tarmac: {line}");
                        1
                    }
                }
            } else {
                eprintln!("tarmac: usage: tarmac open <path>");
                2
            }
        }
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

/// The five-line report. Every value is observed, never inferred: an absent app
/// is reported only when the daemon said so.
fn version_report(sock: &Path) -> String {
    let (daemon, app) = match handshake(sock, Instant::now() + DAEMON_WAIT) {
        Ok((_, info)) => (daemon_line(&info), app_line(&info)),
        Err(NoHandshake::NoDaemon) => ("not running".into(), "unknown (no daemon)".into()),
        Err(failed) => {
            (format!("unreachable ({})", failed.worded(&not_answered())), "unknown (daemon unreachable)".into())
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
    // No file-system call on the path: on a hung volume it would hang the cli,
    // and Ctrl-C could not end it (#267).
    let path = std::path::absolute(raw_path).map_err(|e| format!("cannot open {raw_path}: {e}"))?;

    let no_answer = not_answered();
    let mut stream = connect(&no_answer)?;

    let term_id = calling_term();
    // board_id stays None: the daemon resolves the board from term_id, falling
    // back to the active one.
    let open = proto::encode(&Msg::Open { path: path.to_string_lossy().into_owned(), term_id, board_id: None })
        .map_err(|e| format!("encode failed: {e}"))?;
    exchange(&mut stream, &open, &no_answer)?.map(|()| format!("opened {}", path.display()))
}

#[cfg(test)]
mod tests {
    use std::ffi::{OsStr, OsString};
    use std::os::unix::ffi::OsStrExt;

    use super::term_of;

    #[test]
    fn a_term_id_is_the_value_as_it_is_and_one_that_is_not_utf8_is_none() {
        assert_eq!(term_of(Some("t9".into())), Some("t9".to_string()));
        assert_eq!(term_of(Some(OsString::from(OsStr::from_bytes(b"t\xff9")))), None);
        assert_eq!(term_of(None), None);
    }
}
