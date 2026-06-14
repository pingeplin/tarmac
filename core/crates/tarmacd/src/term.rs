use std::io::{Read, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use tarmac_protocol::Msg;
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, warn};

use crate::state::Daemon;

const OUTPUT_CHUNK: usize = 64 * 1024; // protocol: output chunks <= 64 KiB
// M2 honest signals: poll the foreground process group ~every 750 ms; debounce
// bells to at most one per ~250 ms (docs/protocol.md "M2 honest signals").
const PROC_POLL_INTERVAL: Duration = Duration::from_millis(750);
const BELL_DEBOUNCE: Duration = Duration::from_millis(250);
const BEL: u8 = 0x07;

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
    let handle = Arc::new(TermHandle { input_tx, master: std::sync::Mutex::new(pty.master) });
    daemon.terms.lock().await.insert(term_id.clone(), handle.clone());

    // M2 honest signals: poll the foreground process-group leader and push a
    // term_proc whenever the name changes (the honest "card title = process
    // name"). The loop stops when the term leaves daemon.terms (after exit).
    tokio::spawn(proc_name_loop(daemon.clone(), term_id.clone(), handle));

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
// app always sees output frames before the exit frame. This task holds the
// daemon handle, so it is also where BEL (0x07) detection lives (the blocking
// reader thread has no daemon handle and must not scan).
async fn pump(
    daemon: Arc<Daemon>,
    term_id: String,
    mut out_rx: mpsc::Receiver<Vec<u8>>,
    mut exit_rx: oneshot::Receiver<Option<i64>>,
) {
    // M2 honest signals: push at most one bell per BELL_DEBOUNCE window.
    let mut last_bell: Option<Instant> = None;
    let mut maybe_bell = |chunk: &[u8]| -> bool {
        if !chunk.contains(&BEL) {
            return false;
        }
        let now = Instant::now();
        if last_bell.is_none_or(|t| now.duration_since(t) >= BELL_DEBOUNCE) {
            last_bell = Some(now);
            return true;
        }
        false
    };

    let mut exit_code: Option<Option<i64>> = None;
    loop {
        if exit_code.is_some() {
            // Child is gone; drain whatever output remains, with a grace cap
            // in case a grandchild still holds the pty open.
            match tokio::time::timeout(Duration::from_secs(2), out_rx.recv()).await {
                Ok(Some(chunk)) => {
                    let ring = maybe_bell(&chunk);
                    daemon
                        .push(Msg::Output { term_id: term_id.clone(), bytes: chunk })
                        .await;
                    if ring {
                        daemon.push(Msg::Bell { term_id: term_id.clone() }).await;
                    }
                }
                _ => break,
            }
        } else {
            tokio::select! {
                maybe = out_rx.recv() => match maybe {
                    Some(chunk) => {
                        let ring = maybe_bell(&chunk);
                        daemon
                            .push(Msg::Output { term_id: term_id.clone(), bytes: chunk })
                            .await;
                        if ring {
                            daemon.push(Msg::Bell { term_id: term_id.clone() }).await;
                        }
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
    // M3: drop the term -> board ownership entry (board-scoped provenance ends
    // with the term). The app turns the exit into a dead card per its own state.
    daemon.term_boards.lock().await.remove(&term_id);
    daemon.push(Msg::Exit { term_id, code }).await;
}

// M2 honest signals: poll the foreground process-group leader of the pty every
// PROC_POLL_INTERVAL and push a `term_proc` whenever the name changes (pushing
// once on the first resolve). Stops when the term_id leaves daemon.terms (after
// exit). Any FFI/lock failure just skips the tick — this loop never panics.
async fn proc_name_loop(daemon: Arc<Daemon>, term_id: String, handle: Arc<TermHandle>) {
    let mut last_name: Option<String> = None;
    let mut ticker = tokio::time::interval(PROC_POLL_INTERVAL);
    loop {
        ticker.tick().await;
        // Stop once the term has exited (pump removes it from the registry).
        if !daemon.terms.lock().await.contains_key(&term_id) {
            break;
        }

        // Lock the master only long enough to read the pgrp leader pid; the
        // FFI path resolution happens after the lock is released.
        let pid = {
            let Ok(master) = handle.master.lock() else { continue };
            master.process_group_leader()
        };
        let Some(pid) = pid else { continue };
        let Some(name) = process_name(pid) else { continue };

        if last_name.as_deref() != Some(name.as_str()) {
            last_name = Some(name.clone());
            daemon
                .push(Msg::TermProc { term_id: term_id.clone(), name, pid: Some(pid as i64) })
                .await;
        }
    }
}

// Resolve a pid's executable path via proc_pidpath (macOS) and return the file
// basename. All unsafe FFI is guarded; any failure returns None (skip the tick).
#[cfg(target_os = "macos")]
fn process_name(pid: libc::pid_t) -> Option<String> {
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: buf is a valid, sized allocation; proc_pidpath writes at most
    // `buffersize` bytes and returns the number written (<= buffersize) or <= 0
    // on error. We never read past `len`.
    let len = unsafe {
        libc::proc_pidpath(pid, buf.as_mut_ptr() as *mut libc::c_void, buf.len() as u32)
    };
    if len <= 0 {
        return None;
    }
    buf.truncate(len as usize);
    let path = String::from_utf8_lossy(&buf);
    let base = std::path::Path::new(path.as_ref()).file_name()?.to_string_lossy().into_owned();
    if base.is_empty() { None } else { Some(base) }
}

// Non-macOS fallback (the daemon ships on macOS; keep the crate buildable
// elsewhere): no process-name resolution, so no term_proc is pushed.
#[cfg(not(target_os = "macos"))]
fn process_name(_pid: libc::pid_t) -> Option<String> {
    None
}
