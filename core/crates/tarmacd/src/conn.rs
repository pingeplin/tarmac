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
            Ok(Msg::Open { path, term_id, board_id }) => {
                let reply = match docs::handle_open(&daemon, &path, "cli", term_id, board_id).await {
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

    // On connect: board_list (the full set + active) then the active board's
    // restore (stamped with its id). Compute both under one lock, then send.
    let (board_list, restore) = {
        let boards = daemon.boards.lock().await;
        (boards.board_list_msg(), boards.active_restore_msg())
    };
    let _ = tx.send(board_list).await;
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
        Msg::SpawnTerm { term_id, cols, rows, cwd, cmd, board_id } => {
            // Resolve the owning board: an explicit, known board_id wins, else
            // the active board. Recorded only on a successful spawn.
            let board = {
                let boards = daemon.boards.lock().await;
                board_id
                    .filter(|id| boards.contains(id))
                    .unwrap_or_else(|| boards.active_id().to_string())
            };
            match term::spawn(daemon.clone(), term_id.clone(), cols, rows, cwd, cmd).await {
                Ok(()) => {
                    daemon.term_boards.lock().await.insert(term_id, board);
                }
                Err(e) => {
                    warn!("spawn_term failed: {e}");
                    daemon.push(Msg::Err { msg: e }).await;
                }
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
        Msg::Open { path, term_id, board_id } => {
            // App open: via "user", no reply frame; doc_opened still pushed.
            if let Err(e) = docs::handle_open(daemon, &path, "user", term_id, board_id).await {
                daemon.push(Msg::Err { msg: e }).await;
            }
        }
        Msg::DocRead { path } => {
            // Fire-and-forget, idempotent; an unknown path is not an error.
            // P1: the active board owns every doc; P2 routes by the owning board.
            let known = match daemon.boards.lock().await.active_registry_mut().docs.get_mut(Path::new(&path)) {
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
        Msg::Layout { dock, tiles, board, board_id } => {
            // P1: board_id is absent (single board) ⇒ the active board (board-0).
            // P2's app stamps the active id; the daemon routes by it here.
            daemon
                .boards
                .lock()
                .await
                .registry_for_opt_mut(board_id.as_deref())
                .apply_layout(dock, tiles, board);
            daemon.mark_dirty();
        }
        Msg::BoardSwitch { board_id } => {
            // Make the board active and reply with board_list + its restore.
            // Unknown id is a no-op. The active change is persisted (mark_dirty).
            let msgs = {
                let mut boards = daemon.boards.lock().await;
                boards
                    .set_active(&board_id)
                    .then(|| (boards.board_list_msg(), boards.active_restore_msg()))
            };
            match msgs {
                Some((list, restore)) => {
                    daemon.mark_dirty();
                    daemon.push(list).await;
                    daemon.push(restore).await;
                }
                None => debug!("board_switch to unknown board {board_id}"),
            }
        }
        Msg::BoardCreate => {
            // Mint board-N (made active) and reply with board_list + its restore
            // (a fresh board carries one default terminal tile).
            let (list, restore) = {
                let mut boards = daemon.boards.lock().await;
                boards.create();
                (boards.board_list_msg(), boards.active_restore_msg())
            };
            daemon.mark_dirty();
            daemon.push(list).await;
            daemon.push(restore).await;
        }
        Msg::Unknown => debug!("ignoring unknown message type from app"),
        other => debug!("ignoring unexpected app message: {other:?}"),
    }
}
