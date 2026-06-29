mod conn;
mod docs;
mod persist;
mod state;
mod term;

use std::ffi::OsString;
use std::path::PathBuf;
use tarmac_protocol::{Channel, channel_label, check_socket_path_len, resolve_socket_path, resolve_state_path};
use tokio::net::UnixListener;
use tracing::{error, info, warn};

/// The ONE audited build-config → Channel mapping for this binary (spec
/// 2606.0003): a debug build is the `dev` channel, a release build `release`.
/// Centralised so `cfg!(debug_assertions)` is never sprinkled through the path
/// code — see the `core/Cargo.toml` note forbidding `debug-assertions` profile
/// overrides, which would silently flip this without touching path code.
fn current_channel() -> Channel {
    if cfg!(debug_assertions) {
        Channel::Dev
    } else {
        Channel::Release
    }
}

fn home_dir() -> OsString {
    std::env::var_os("HOME").unwrap_or_else(|| OsString::from("/"))
}

fn socket_path() -> PathBuf {
    let over = std::env::var_os("TARMAC_SOCKET").filter(|v| !v.is_empty());
    resolve_socket_path(over, &home_dir(), current_channel())
}

fn state_path() -> PathBuf {
    let over = std::env::var_os("TARMAC_STATE").filter(|v| !v.is_empty());
    resolve_state_path(over, &home_dir(), current_channel())
}

// Per docs/protocol.md: if the socket file exists, try connecting — success
// means a live daemon (log + exit 1); failure means stale (unlink + bind).
fn claim_socket(path: &PathBuf) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if path.exists() {
        match std::os::unix::net::UnixStream::connect(path) {
            Ok(_) => {
                error!("another tarmacd is already listening on {}", path.display());
                std::process::exit(1);
            }
            Err(_) => {
                warn!("removing stale socket {}", path.display());
                std::fs::remove_file(path)?;
            }
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let sock = socket_path();
    if let Err(msg) = check_socket_path_len(&sock) {
        return Err(anyhow::anyhow!("{msg}"));
    }
    claim_socket(&sock)?;
    let listener = UnixListener::bind(&sock)?;
    info!("tarmacd ({}) listening on {}", channel_label(current_channel()), sock.display());

    let daemon = state::Daemon::new(state_path())?;

    let sock_for_signal = sock.clone();
    tokio::spawn(async move {
        use tokio::signal::unix::{SignalKind, signal};
        let mut sigterm = signal(SignalKind::terminate()).expect("install SIGTERM handler");
        let mut sigint = signal(SignalKind::interrupt()).expect("install SIGINT handler");
        tokio::select! {
            _ = sigterm.recv() => {}
            _ = sigint.recv() => {}
        }
        info!("shutting down");
        let _ = std::fs::remove_file(&sock_for_signal);
        std::process::exit(0);
    });

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let d = daemon.clone();
                tokio::spawn(async move { conn::handle(d, stream).await });
            }
            Err(e) => warn!("accept failed: {e}"),
        }
    }
}
