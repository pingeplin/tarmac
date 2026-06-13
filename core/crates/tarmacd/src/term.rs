use std::io::{Read, Write};
use std::sync::Arc;
use std::time::Duration;

use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use tarmac_protocol::Msg;
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, warn};

use crate::state::Daemon;

const OUTPUT_CHUNK: usize = 64 * 1024; // protocol: output chunks <= 64 KiB

pub struct TermHandle {
    pub input_tx: mpsc::Sender<Vec<u8>>,
    master: std::sync::Mutex<Box<dyn MasterPty + Send>>,
}

impl TermHandle {
    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), String> {
        self.master
            .lock()
            .expect("master lock")
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| format!("resize failed: {e}"))
    }
}

pub async fn spawn(
    daemon: Arc<Daemon>,
    term_id: String,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
    cmd: Option<Vec<String>>,
) -> Result<(), String> {
    if daemon.terms.lock().await.contains_key(&term_id) {
        return Err(format!("term_id already in use: {term_id}"));
    }

    let argv = match cmd {
        Some(v) if !v.is_empty() => v,
        Some(_) => return Err("cmd must be a non-empty argv".into()),
        None => {
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
            vec![shell, "-il".into()]
        }
    };
    let cwd = cwd
        .unwrap_or_else(|| std::env::var("HOME").unwrap_or_else(|_| "/".into()));

    let pty = native_pty_system()
        .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| format!("openpty failed: {e}"))?;

    let mut builder = CommandBuilder::new(&argv[0]);
    builder.args(&argv[1..]);
    builder.cwd(cwd);
    builder.env("TERM", "xterm-256color"); // rest of env inherited
    // v4 Phase 3 provenance: a `tarmac open` run inside this pty reads
    // TARMAC_TERM_ID to attribute the open to its calling terminal card.
    builder.env("TARMAC_TERM_ID", &term_id);

    let child = pty
        .slave
        .spawn_command(builder)
        .map_err(|e| format!("spawn failed: {e}"))?;
    // Drop the slave or the master reader never sees EOF.
    drop(pty.slave);

    let mut reader = pty
        .master
        .try_clone_reader()
        .map_err(|e| format!("pty reader unavailable: {e}"))?;
    let mut writer = pty
        .master
        .take_writer()
        .map_err(|e| format!("pty writer unavailable: {e}"))?;

    let (input_tx, mut input_rx) = mpsc::channel::<Vec<u8>>(256);
    daemon.terms.lock().await.insert(
        term_id.clone(),
        Arc::new(TermHandle { input_tx, master: std::sync::Mutex::new(pty.master) }),
    );

    let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>(256);
    tokio::task::spawn_blocking(move || {
        let mut buf = vec![0u8; OUTPUT_CHUNK];
        loop {
            match reader.read(&mut buf) {
                // macOS returns EIO (not Ok(0)) once the child is gone.
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out_tx.blocking_send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });

    tokio::task::spawn_blocking(move || {
        while let Some(bytes) = input_rx.blocking_recv() {
            if writer.write_all(&bytes).is_err() {
                break;
            }
            let _ = writer.flush();
        }
    });

    let (exit_tx, exit_rx) = oneshot::channel::<Option<i64>>();
    let mut child = child;
    tokio::task::spawn_blocking(move || {
        // signal() is the protocol's nil marker; the code is forced to 1
        // for signal deaths and must not be trusted.
        let code = match child.wait() {
            Ok(status) => {
                if status.signal().is_some() {
                    None
                } else {
                    Some(status.exit_code() as i64)
                }
            }
            Err(_) => None,
        };
        let _ = exit_tx.send(code);
    });

    tokio::spawn(pump(daemon, term_id, out_rx, exit_rx));
    Ok(())
}

// Forwards output to the app, then sends exit after output is drained so the
// app always sees output frames before the exit frame.
async fn pump(
    daemon: Arc<Daemon>,
    term_id: String,
    mut out_rx: mpsc::Receiver<Vec<u8>>,
    mut exit_rx: oneshot::Receiver<Option<i64>>,
) {
    let mut exit_code: Option<Option<i64>> = None;
    loop {
        if exit_code.is_some() {
            // Child is gone; drain whatever output remains, with a grace cap
            // in case a grandchild still holds the pty open.
            match tokio::time::timeout(Duration::from_secs(2), out_rx.recv()).await {
                Ok(Some(chunk)) => {
                    daemon
                        .push(Msg::Output { term_id: term_id.clone(), bytes: chunk })
                        .await;
                }
                _ => break,
            }
        } else {
            tokio::select! {
                maybe = out_rx.recv() => match maybe {
                    Some(chunk) => {
                        daemon
                            .push(Msg::Output { term_id: term_id.clone(), bytes: chunk })
                            .await;
                    }
                    None => {
                        exit_code = Some((&mut exit_rx).await.unwrap_or(None));
                        break;
                    }
                },
                code = &mut exit_rx => {
                    exit_code = Some(code.unwrap_or(None));
                }
            }
        }
    }
    let code = exit_code.flatten();
    debug!("term {term_id} exited with {code:?}");
    if daemon.terms.lock().await.remove(&term_id).is_none() {
        warn!("term {term_id} missing from registry at exit");
    }
    daemon.push(Msg::Exit { term_id, code }).await;
}
