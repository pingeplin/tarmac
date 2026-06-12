use std::path::Path;
use std::sync::Arc;

use tarmac_protocol::{self as proto, Msg, PROTOCOL_VERSION, frame};
use tokio::io::AsyncWrite;
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::state::Daemon;
use crate::{docs, term};

pub async fn handle(daemon: Arc<Daemon>, stream: UnixStream) {
    if let Err(e) = handshake(daemon, stream).await {
        debug!("connection ended: {e}");
    }
}

async fn write_msg(
    w: &mut (impl AsyncWrite + Unpin),
    msg: &Msg,
) -> anyhow::Result<()> {
    let payload = proto::encode(msg)?;
    frame::write_async(w, &payload).await?;
    Ok(())
}

async fn handshake(daemon: Arc<Daemon>, mut stream: UnixStream) -> anyhow::Result<()> {
    let first = frame::read_async(&mut stream).await?;
    let (role, v) = match proto::decode(&first) {
        Ok(Msg::Hello { role, v }) => (role, v),
        Ok(other) => {
            write_msg(&mut stream, &Msg::Err { msg: format!("expected hello, got {other:?}") })
                .await?;
            return Ok(());
        }
        Err(e) => {
            write_msg(&mut stream, &Msg::Err { msg: format!("malformed hello: {e}") }).await?;
            return Ok(());
        }
    };
    if v != PROTOCOL_VERSION {
        write_msg(&mut stream, &Msg::Err { msg: format!("unsupported protocol version: {v}") })
            .await?;
        return Ok(());
    }
    match role.as_str() {
        "cli" => {
            write_msg(&mut stream, &Msg::HelloOk { v: PROTOCOL_VERSION }).await?;
            cli_session(daemon, stream).await
        }
        "app" => {
            write_msg(&mut stream, &Msg::HelloOk { v: PROTOCOL_VERSION }).await?;
            app_session(daemon, stream).await
        }
        other => {
            write_msg(&mut stream, &Msg::Err { msg: format!("unsupported role: {other}") })
                .await?;
            Ok(())
        }
    }
}

async fn cli_session(daemon: Arc<Daemon>, mut stream: UnixStream) -> anyhow::Result<()> {
    loop {
        let payload = match frame::read_async(&mut stream).await {
            Ok(p) => p,
            Err(_) => return Ok(()), // client closed (normal) or protocol error: drop
        };
        match proto::decode(&payload) {
            Ok(Msg::Open { path }) => {
                let reply = match docs::handle_open(&daemon, &path, "cli").await {
                    Ok(()) => Msg::Ack,
                    Err(msg) => Msg::Err { msg },
                };
                write_msg(&mut stream, &reply).await?;
            }
            Ok(Msg::Unknown) => debug!("ignoring unknown message type from cli"),
            Ok(other) => debug!("ignoring unexpected cli message: {other:?}"),
            Err(e) => {
                write_msg(&mut stream, &Msg::Err { msg: format!("malformed frame: {e}") })
                    .await?;
            }
        }
    }
}

async fn app_session(daemon: Arc<Daemon>, stream: UnixStream) -> anyhow::Result<()> {
    let (mut rd, mut wr) = stream.into_split();
    let (tx, mut rx) = mpsc::channel::<Msg>(256);
    let (generation, cancel) = daemon.install_app(tx.clone()).await;
    info!("app connected (generation {generation})");

    let writer_cancel = cancel.clone();
    tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            let Ok(payload) = proto::encode(&msg) else { continue };
            if frame::write_async(&mut wr, &payload).await.is_err() {
                writer_cancel.cancel();
                break;
            }
        }
    });

    // Restore frame immediately after hello_ok, per docs/protocol.md:
    // docs in dock order plus the persisted tile order.
    let restore = daemon.registry.lock().await.restore_msg();
    let _ = tx.send(restore).await;

    loop {
        let payload = tokio::select! {
            _ = cancel.cancelled() => break,
            res = frame::read_async(&mut rd) => match res {
                Ok(p) => p,
                Err(_) => break,
            },
        };
        match proto::decode(&payload) {
            Ok(msg) => dispatch_app_msg(&daemon, msg).await,
            Err(e) => {
                daemon.push(Msg::Err { msg: format!("malformed frame: {e}") }).await;
            }
        }
    }

    daemon.remove_app(generation).await;
    info!("app disconnected (generation {generation})");
    Ok(())
}

async fn dispatch_app_msg(daemon: &Arc<Daemon>, msg: Msg) {
    match msg {
        Msg::SpawnTerm { term_id, cols, rows, cwd, cmd } => {
            if let Err(e) = term::spawn(daemon.clone(), term_id, cols, rows, cwd, cmd).await {
                warn!("spawn_term failed: {e}");
                daemon.push(Msg::Err { msg: e }).await;
            }
        }
        Msg::Input { term_id, bytes } => {
            let handle = daemon.terms.lock().await.get(&term_id).cloned();
            match handle {
                Some(h) => {
                    let _ = h.input_tx.send(bytes).await;
                }
                None => debug!("input for unknown term {term_id}"),
            }
        }
        Msg::Resize { term_id, cols, rows } => {
            let handle = daemon.terms.lock().await.get(&term_id).cloned();
            match handle {
                Some(h) => {
                    if let Err(e) = h.resize(cols, rows) {
                        warn!("{e}");
                    }
                }
                None => debug!("resize for unknown term {term_id}"),
            }
        }
        Msg::Open { path } => {
            // App open: via "user", no reply frame; doc_opened still pushed.
            if let Err(e) = docs::handle_open(daemon, &path, "user").await {
                daemon.push(Msg::Err { msg: e }).await;
            }
        }
        Msg::DocRead { path } => {
            // Fire-and-forget, idempotent; an unknown path is not an error.
            let known = match daemon.registry.lock().await.docs.get_mut(Path::new(&path)) {
                Some(info) => {
                    info.read = true;
                    true
                }
                None => false,
            };
            if known {
                daemon.mark_dirty();
            } else {
                debug!("doc_read for unknown path {path}");
            }
        }
        Msg::Layout { dock, tiles } => {
            daemon.registry.lock().await.apply_layout(dock, tiles);
            daemon.mark_dirty();
        }
        Msg::Unknown => debug!("ignoring unknown message type from app"),
        other => debug!("ignoring unexpected app message: {other:?}"),
    }
}
