use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use tarmac_protocol::{self as proto, Msg, frame};

const HELP: &str = "\
tarmac — agent cockpit CLI

USAGE:
    tarmac open <path>      register a file with the running tarmac app
    tarmac --help           show this help

`tarmac open` is fire-and-forget: anything (you, an agent, a Makefile, a git
hook) can run it to surface a doc in the cockpit. The path is canonicalized
and must point to an existing file.

The daemon socket defaults to ~/Library/Application Support/tarmac/tarmacd.sock
(release builds) or ~/Library/Application Support/tarmac/dev/tarmacd.sock (dev
builds); override with TARMAC_SOCKET.

EXIT STATUS:
    0  the daemon acknowledged the open
    1  the daemon rejected it, or no daemon is running
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

fn socket_path() -> PathBuf {
    let over = std::env::var_os("TARMAC_SOCKET").filter(|v| !v.is_empty());
    let home = std::env::var_os("HOME").unwrap_or_else(|| std::ffi::OsString::from("/"));
    proto::resolve_socket_path(over, &home, current_channel())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("-h") | Some("--help") | Some("help") => {
            print!("{HELP}");
            std::process::exit(0);
        }
        Some("open") => {}
        Some(other) => {
            eprintln!("tarmac: unknown command '{other}' (see tarmac --help)");
            std::process::exit(2);
        }
        None => {
            eprint!("{HELP}");
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

fn open(raw_path: &str) -> Result<String, String> {
    let canon = std::fs::canonicalize(raw_path)
        .map_err(|e| format!("cannot open {raw_path}: {e}"))?;
    let meta = std::fs::metadata(&canon)
        .map_err(|e| format!("cannot stat {}: {e}", canon.display()))?;
    if !meta.is_file() {
        return Err(format!("not a regular file: {}", canon.display()));
    }

    let sock = socket_path();
    let mut stream = UnixStream::connect(&sock).map_err(|_| {
        format!(
            "no tarmac daemon running ({} channel, socket: {})",
            proto::channel_label(current_channel()),
            sock.display()
        )
    })?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    send(&mut stream, &Msg::Hello { role: "cli".into(), v: proto::PROTOCOL_VERSION })?;
    match recv(&mut stream)? {
        Msg::HelloOk { .. } => {}
        Msg::Err { msg } => return Err(format!("daemon rejected handshake: {msg}")),
        other => return Err(format!("unexpected handshake reply: {other:?}")),
    }

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
