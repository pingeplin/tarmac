use std::collections::{HashMap, HashSet};
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

/// The daemon's handshake reply, stamping this build's version and OS pid so the
/// app can detect a post-upgrade mismatch and SIGTERM the running daemon by pid.
fn hello_ok() -> Msg {
    Msg::HelloOk {
        v: PROTOCOL_VERSION,
        daemon_version: Some(env!("CARGO_PKG_VERSION").into()),
        daemon_pid: Some(std::process::id()),
    }
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
            write_msg(&mut stream, &hello_ok()).await?;
            cli_session(daemon, stream).await
        }
        "app" => {
            write_msg(&mut stream, &hello_ok()).await?;
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

// Per-connection app state threaded through the dispatch loop.
struct AppConn {
    tx: mpsc::Sender<Msg>,
    // Boards whose restore (and thus scrollback replay) has already been sent on
    // THIS connection. A board is replayed at most once per connection — the very
    // first time its restore is emitted (connect for the active board, the first
    // switch for the rest). A switch-back does not replay: the app kept its
    // backgrounded views fed live, so a second replay would duplicate.
    replayed: HashSet<String>,
}

// Per-board live-pty counts for board_list, derived from the live_terms map.
fn running_from(by_board: &HashMap<String, Vec<String>>) -> HashMap<String, u32> {
    by_board.iter().map(|(id, v)| (id.clone(), v.len() as u32)).collect()
}

// Stamp a Restore with the board's live term_ids (the daemon-owned shells the
// app re-binds to instead of cold-spawning). A no-op for non-Restore msgs.
fn stamp_live_terms(mut restore: Msg, live_terms: Vec<String>) -> Msg {
    if let Msg::Restore { live_terms: lt, .. } = &mut restore {
        *lt = live_terms;
    }
    restore
}

// Snapshot each live term's scrollback ring (a copy — the std::sync::Mutex is
// never held across an await). Empty rings are skipped.
async fn snapshot_scrollback(daemon: &Arc<Daemon>, term_ids: &[String]) -> Vec<(String, Vec<u8>)> {
    let mut out = Vec::new();
    for tid in term_ids {
        let handle = daemon.terms.lock().await.get(tid).cloned();
        if let Some(h) = handle {
            let data = h.scrollback_snapshot();
            if !data.is_empty() {
                out.push((tid.clone(), data));
            }
        }
    }
    out
}

// Send a board_list + that board's restore, then replay the board's live
// scrollback exactly once per connection (the first time we send its restore).
// Replay bypasses the BEL scan (frames are built here, not in the pump), so a
// 0x07 in history never re-rings. A board the app kept fed live on switch-back
// is already in `replayed`, so it is not replayed again.
async fn send_board(
    daemon: &Arc<Daemon>,
    conn: &mut AppConn,
    board_list: Msg,
    restore: Msg,
    board_id: &str,
    live_terms: &[String],
) {
    let first = !conn.replayed.contains(board_id);
    // Snapshot before sending the restore: a chunk produced after this is
    // delivered live and arrives before the restore (FIFO) while the term is
    // still unbound app-side, so the app drops it — replay + live never dup.
    let replay = if first { snapshot_scrollback(daemon, live_terms).await } else { Vec::new() };
    let _ = conn.tx.send(board_list).await;
    let _ = conn.tx.send(restore).await;
    if first {
        conn.replayed.insert(board_id.to_string());
        for (tid, data) in replay {
            for chunk in data.chunks(term::OUTPUT_CHUNK) {
                let _ = conn.tx.send(Msg::Output { term_id: tid.clone(), bytes: chunk.to_vec() }).await;
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
    // restore — stamped with its id and its live term_ids — followed by each live
    // term's scrollback replay, so the app re-binds to running shells instead of
    // cold-spawning. live_terms_by_board gives the running counts (board_list) and
    // the active board's live terms (restore + replay) in one lock pass.
    let by_board = daemon.live_terms_by_board().await;
    let running = running_from(&by_board);
    let (board_list, restore, active_id) = {
        let boards = daemon.boards.lock().await;
        (boards.board_list_msg(&running), boards.active_restore_msg(), boards.active_id().to_string())
    };
    let active_live = by_board.get(&active_id).cloned().unwrap_or_default();
    let restore = stamp_live_terms(restore, active_live.clone());

    let mut conn = AppConn { tx: tx.clone(), replayed: HashSet::new() };
    send_board(&daemon, &mut conn, board_list, restore, &active_id, &active_live).await;

    loop {
        let payload = tokio::select! {
            _ = cancel.cancelled() => break,
            res = frame::read_async(&mut rd) => match res {
                Ok(p) => p,
                Err(_) => break,
            },
        };
        match proto::decode(&payload) {
            Ok(msg) => dispatch_app_msg(&daemon, &mut conn, msg).await,
            Err(e) => {
                daemon.push(Msg::Err { msg: format!("malformed frame: {e}") }).await;
            }
        }
    }

    daemon.remove_app(generation).await;
    info!("app disconnected (generation {generation})");
    Ok(())
}

async fn dispatch_app_msg(daemon: &Arc<Daemon>, conn: &mut AppConn, msg: Msg) {
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
                    // P5: no board_list re-push here. A spawn is always app-
                    // initiated for a board the app is building, so it already
                    // knows the new running count; the connect-time board_list
                    // already reflects surviving ptys. Only the *exit* re-push
                    // (term.rs) is load-bearing — it tells the app about a term
                    // dying on a board it has not rebuilt this session.
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
        Msg::TermClose { term_id } => {
            // issue #15: kill one terminal's process group (SIGHUP) so ⌘W can
            // close a single card. Clone the handle and drop the terms lock
            // before kill() (board-delete's lock discipline); the pump's wait
            // thread then runs the normal exit cleanup (terms/term_boards removal,
            // Exit + board_list). An unknown term_id is a no-op.
            let handle = daemon.terms.lock().await.get(&term_id).cloned();
            match handle {
                Some(h) => h.kill(),
                None => debug!("term_close for unknown term {term_id}"),
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
            // Make the board active and reply with board_list + its restore (+ a
            // first-time scrollback replay so the app re-binds to the board's live
            // shells). Unknown id is a no-op. The active change is persisted.
            let by_board = daemon.live_terms_by_board().await;
            let running = running_from(&by_board);
            let msgs = {
                let mut boards = daemon.boards.lock().await;
                boards
                    .set_active(&board_id)
                    .then(|| (boards.board_list_msg(&running), boards.active_restore_msg()))
            };
            match msgs {
                Some((list, restore)) => {
                    let live = by_board.get(&board_id).cloned().unwrap_or_default();
                    let restore = stamp_live_terms(restore, live.clone());
                    daemon.mark_dirty();
                    send_board(daemon, conn, list, restore, &board_id, &live).await;
                }
                None => debug!("board_switch to unknown board {board_id}"),
            }
        }
        Msg::BoardCreate => {
            // Mint board-N (made active) and reply with board_list + its restore
            // (a fresh board carries one default terminal tile and no live terms).
            let by_board = daemon.live_terms_by_board().await;
            let running = running_from(&by_board);
            let (list, restore, new_id) = {
                let mut boards = daemon.boards.lock().await;
                let new_id = boards.create();
                (boards.board_list_msg(&running), boards.active_restore_msg(), new_id)
            };
            let live = by_board.get(&new_id).cloned().unwrap_or_default();
            let restore = stamp_live_terms(restore, live.clone());
            daemon.mark_dirty();
            send_board(daemon, conn, list, restore, &new_id, &live).await;
        }
        Msg::BoardRename { board_id, name } => {
            // Set (or clear, on an empty name) the board's display name and
            // re-push board_list so the switcher row updates. The boards lock is
            // taken alone; the board_list re-push computes running counts without
            // it held (same discipline as term.rs's exit re-push).
            let renamed = daemon
                .boards
                .lock()
                .await
                .rename(&board_id, (!name.is_empty()).then_some(name));
            if renamed {
                daemon.mark_dirty();
                daemon.push(daemon.board_list_msg().await).await;
            } else {
                debug!("board_rename for unknown board {board_id}");
            }
        }
        Msg::BoardDelete { board_id } => {
            // Refuse early (killing nothing) when the board can't be deleted — the
            // last board or an unknown id; delete() re-checks authoritatively.
            let deletable = {
                let boards = daemon.boards.lock().await;
                boards.contains(&board_id) && boards.iter().count() > 1
            };
            if deletable {
                // Lock discipline: each map is locked alone and dropped before the
                // next; kill runs with NO lock held; std::sync::Mutex never spans
                // an await. 1) snapshot the board's term_ids (term_boards).
                let term_ids: Vec<String> = daemon
                    .term_boards
                    .lock()
                    .await
                    .iter()
                    .filter(|(_, b)| b.as_str() == board_id)
                    .map(|(t, _)| t.clone())
                    .collect();
                // 2) clone their handles (terms), dropping the lock before kill.
                let handles: Vec<_> = {
                    let terms = daemon.terms.lock().await;
                    term_ids.iter().filter_map(|t| terms.get(t).cloned()).collect()
                };
                // 3) kill the groups with no lock held; each pump's wait thread
                //    then runs the normal exit cleanup (terms/term_boards removal,
                //    Exit + board_list push). The delete arm never touches those.
                for h in &handles {
                    h.kill();
                }
                // 4) remove the board (active is fixed if it was the active one).
                let deleted = daemon.boards.lock().await.delete(&board_id);
                if deleted {
                    daemon.mark_dirty();
                    // 5) re-push board_list + the now-active board's restore. The
                    //    active board changed iff we deleted the active one; either
                    //    way the app needs the list (and a restore to mount the new
                    //    active board when it changed). Same send_board sequence as
                    //    BoardSwitch, keyed off the post-delete active board.
                    let by_board = daemon.live_terms_by_board().await;
                    let running = running_from(&by_board);
                    let (list, restore, active_id) = {
                        let boards = daemon.boards.lock().await;
                        (
                            boards.board_list_msg(&running),
                            boards.active_restore_msg(),
                            boards.active_id().to_string(),
                        )
                    };
                    let live = by_board.get(&active_id).cloned().unwrap_or_default();
                    let restore = stamp_live_terms(restore, live.clone());
                    send_board(daemon, conn, list, restore, &active_id, &live).await;
                }
            } else {
                debug!("board_delete refused for {board_id} (last board or unknown)");
            }
        }
        Msg::DocClose { path } => {
            let path_buf = std::path::PathBuf::from(&path);
            let parent = path_buf.parent().map(std::path::Path::to_path_buf);
            // Lock boards, prune docs + dock, compute whether a sibling doc in
            // the same dir remains; drop the lock before any unwatch/await.
            let (removed, should_unwatch) = {
                let mut boards = daemon.boards.lock().await;
                boards.active_registry_mut().close_doc(&path_buf)
            };
            if removed {
                daemon.mark_dirty();
                if should_unwatch {
                    if let Some(dir) = parent {
                        daemon.unwatch(&dir);
                    }
                }
            } else {
                debug!("doc_close for unknown path {path}");
            }
        }
        Msg::Unknown => debug!("ignoring unknown message type from app"),
        other => debug!("ignoring unexpected app message: {other:?}"),
    }
}
