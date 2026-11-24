// The daemon's own rules, beside the workspace lint table (core/Cargo.toml):
// a failure it cannot recover from says why (`.expect("…")`), and it logs
// with `tracing`, never by printing (docs/coding-style.md §3).
#![warn(clippy::unwrap_used, clippy::print_stdout, clippy::print_stderr)]

mod app_writer;
mod bell_scan;
mod boards;
mod conn;
mod docs;
mod events;
mod fd_limit;
#[cfg(test)]
mod fixtures;
mod holder;
mod panic_log;
mod persist;
mod proc;
mod reader;
mod reports;
mod resume;
mod state;
// Compiled out of release builds: only a test harness asks for it.
#[cfg(debug_assertions)]
mod stdin_eof;
mod term;
mod watch;

use std::ffi::OsString;
use std::path::PathBuf;
use tarmac_protocol::{Channel, channel_label, check_socket_path_len, resolve_socket_path, resolve_state_path};
use tokio::net::UnixListener;
use tokio::signal::unix::{SignalKind, signal};
use tracing::{error, info, warn};

const ACCEPT_RETRY: std::time::Duration = std::time::Duration::from_millis(100);

/// The ONE audited build-config → Channel mapping for this binary: a debug
/// build is the `dev` channel, a release build `release`.
/// Centralised so `cfg!(debug_assertions)` is never sprinkled through the path
/// code — see the `core/Cargo.toml` note forbidding `debug-assertions` profile
/// overrides, which would silently flip this without touching path code.
fn current_channel() -> Channel {
    if cfg!(debug_assertions) { Channel::Dev } else { Channel::Release }
}

/// One environment variable's value: the process's, or a test's table.
type Env<'a> = &'a dyn Fn(&str) -> Option<OsString>;

fn process_env(name: &str) -> Option<OsString> {
    std::env::var_os(name)
}

/// Resolves when the test harness that started this daemon is gone (`stdin_eof`).
#[cfg(debug_assertions)]
async fn harness_gone() {
    stdin_eof::reached(&process_env).await;
}

#[cfg(not(debug_assertions))]
async fn harness_gone() {
    std::future::pending::<()>().await;
}

fn home_dir(env: Env) -> OsString {
    env("HOME").unwrap_or_else(|| OsString::from("/"))
}

fn socket_path() -> PathBuf {
    socket_path_from(&process_env, current_channel())
}

fn socket_path_from(env: Env, channel: Channel) -> PathBuf {
    let over = env("TARMAC_SOCKET").filter(|v| !v.is_empty());
    resolve_socket_path(over, &home_dir(env), channel)
}

fn state_path() -> PathBuf {
    let over = std::env::var_os("TARMAC_STATE").filter(|v| !v.is_empty());
    resolve_state_path(over, &home_dir(&process_env), current_channel())
}

// Per docs/protocol.md: if the socket file exists, try connecting — success
// means a live daemon (log + exit 1); failure means stale (unlink + bind).
fn claim_socket(path: &PathBuf) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if path.exists() {
        #[expect(
            clippy::redundant_pattern_matching,
            reason = "is_ok() would close the probe connection before the log and the exit"
        )]
        if let Ok(_) = std::os::unix::net::UnixStream::connect(path) {
            error!("another tarmacd is already listening on {}", path.display());
            #[expect(clippy::exit, reason = "docs/protocol.md: a live daemon on the socket means log and exit 1")]
            std::process::exit(1);
        } else {
            warn!("removing stale socket {}", path.display());
            std::fs::remove_file(path)?;
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if std::env::args().any(|a| a == "--version") {
        #[expect(
            clippy::print_stdout,
            reason = "`--version` answers on stdout, before the tracing subscriber is set up"
        )]
        {
            println!("{}", env!("CARGO_PKG_VERSION"));
        }
        std::process::exit(0);
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        // On a failed write the fmt layer falls back to `eprintln!`, which
        // panics; inside the panic hook that is an abort.
        .log_internal_errors(false)
        .init();
    panic_log::install();
    fd_limit::raise();

    let sock = socket_path();
    if let Err(msg) = check_socket_path_len(&sock) {
        return Err(anyhow::anyhow!("{msg}"));
    }
    claim_socket(&sock)?;
    // Installed before the bind: the socket must not be connectable before the
    // handlers exist, or a signal arriving in that window takes its default
    // action and kills the process.
    let mut sighup = signal(SignalKind::hangup())?;
    let mut sigterm = signal(SignalKind::terminate())?;
    let mut sigint = signal(SignalKind::interrupt())?;
    let listener = UnixListener::bind(&sock)?;
    info!("tarmacd ({}) listening on {}", channel_label(current_channel()), sock.display());

    let daemon = state::Daemon::new(state_path()).await?;

    let sock_for_signal = sock.clone();
    let daemon_for_signal = daemon.clone();
    tokio::spawn(async move {
        // SIGHUP included: it is what a terminal sends its session on teardown,
        // and it was the one death that skipped the unlink.
        tokio::select! {
            _ = sighup.recv() => {}
            _ = sigterm.recv() => {}
            _ = sigint.recv() => {}
            () = harness_gone() => {}
        }
        info!("shutting down");
        // Saved before the socket goes: an app that waits for the socket to
        // go then finds the state a new daemon restores.
        daemon_for_signal.final_save().await;
        let _ = std::fs::remove_file(&sock_for_signal);
        std::process::exit(0);
    });

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                // Read before any await: the peer's pid can be read only while
                // its end is open.
                let peer_pid = stream.peer_cred().ok().and_then(|cred| cred.pid());
                let d = daemon.clone();
                tokio::spawn(async move { conn::handle(d, stream, peer_pid).await });
            }
            // Out of descriptors (EMFILE) the next accept would fail too;
            // the pause keeps the loop from retrying at once.
            Err(e) => {
                warn!("accept failed: {e}");
                tokio::time::sleep(ACCEPT_RETRY).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use tarmac_protocol::Channel;

    use super::socket_path_from;

    /// The `socket` rows of the table that tarmac-cli's `socket_path` and the
    /// Swift `DaemonClient.resolveSocketPath` run too.
    #[test]
    fn each_row_of_the_shared_socket_table() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tarmac-protocol/tests/fixtures/socket_path_cases.json");
        let table: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        let rows = table["socket"].as_array().unwrap();
        let channel = |row: &serde_json::Value| match row["channel"].as_str() {
            Some("dev") => Channel::Dev,
            Some("release") => Channel::Release,
            other => panic!("no channel {other:?}"),
        };
        assert_eq!(rows.len(), 15);
        assert!([Channel::Dev, Channel::Release].iter().all(|c| rows.iter().any(|row| channel(row) == *c)));
        for row in rows {
            let env = |name: &str| row["env"].get(name).map(|v| OsString::from(v.as_str().unwrap()));
            assert_eq!(socket_path_from(&env, channel(row)).to_str(), row["path"].as_str(), "{row}");
        }
    }
}
