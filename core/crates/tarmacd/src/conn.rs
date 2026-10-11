use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

use tarmac_protocol::{self as proto, Msg, PROTOCOL_VERSION, frame};
use tokio::io::AsyncWrite;
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::boards::{BoardId, Boards};
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

async fn reject(w: &mut (impl AsyncWrite + Unpin), msg: String) -> anyhow::Result<()> {
    write_msg(w, &Msg::Err { msg }).await
}

/// The daemon's handshake reply, stamping this build's version and OS pid so the
/// app can detect a post-upgrade mismatch and SIGTERM the running daemon by pid.
///
/// `app` describes the app slot for `tarmac --version`: `None` makes no claim,
/// `Some((connected, version))` reports what the daemon actually observes. Only
/// `cli` clients get a claim — telling an app that no app is connected would be
/// false while a predecessor still holds the slot.
fn hello_ok(app: Option<(bool, Option<String>)>) -> Msg {
    let (app_connected, app_version) = match app {
        Some((connected, version)) => (Some(connected), version),
        None => (None, None),
    };
    Msg::HelloOk {
        v: PROTOCOL_VERSION,
        daemon_version: Some(env!("CARGO_PKG_VERSION").into()),
        daemon_pid: Some(std::process::id()),
        app_version,
        app_connected,
    }
}

async fn handshake(daemon: Arc<Daemon>, mut stream: UnixStream) -> anyhow::Result<()> {
    let first = frame::read_async(&mut stream).await?;
    let (role, v, app_version) = match proto::decode(&first) {
        Ok(Msg::Hello { role, v, app_version }) => (role, v, app_version),
        Ok(other) => return reject(&mut stream, format!("expected hello, got {other:?}")).await,
        Err(e) => return reject(&mut stream, format!("malformed hello: {e}")).await,
    };
    if v != PROTOCOL_VERSION {
        return reject(&mut stream, format!("unsupported protocol version: {v}")).await;
    }
    match role.as_str() {
        "cli" => {
            let slot = daemon.app_slot_version().await;
            write_msg(&mut stream, &hello_ok(Some(slot))).await?;
            cli_session(daemon, stream).await
        }
        "app" => {
            write_msg(&mut stream, &hello_ok(None)).await?;
            app_session(daemon, stream, app_version).await
        }
        other => reject(&mut stream, format!("unsupported role: {other}")).await,
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
            Err(e) => reject(&mut stream, format!("malformed frame: {e}")).await?,
        }
    }
}

struct AppConn {
    tx: mpsc::Sender<Msg>,
    // Boards whose restore (and thus scrollback replay) has already been sent on
    // THIS connection. A board is replayed at most once per connection — the very
    // first time its restore is emitted (connect for the active board, the first
    // switch for the rest). A switch-back does not replay: the app kept its
    // backgrounded views fed live, so a second replay would duplicate.
    replayed: HashSet<BoardId>,
}

// Each ring is copied under its std::sync::Mutex, never held across an await.
// Empty rings are skipped.
async fn snapshot_scrollback(daemon: &Daemon, term_ids: &[String]) -> Vec<(String, Vec<u8>)> {
    let mut out = Vec::new();
    for tid in term_ids {
        if let Some(h) = daemon.term(tid).await {
            let data = h.scrollback_snapshot();
            if !data.is_empty() {
                out.push((tid.clone(), data));
            }
        }
    }
    out
}

async fn send_active_board(daemon: &Daemon, conn: &mut AppConn) {
    change_and_send_active_board(daemon, conn, |_| true).await;
}

// Sends board_list, then the active board's restore, then — the first time this
// connection sees the board — each live term's scrollback. Replay bypasses the
// BEL scan (frames are built here, not in the pump), so a 0x07 in history never
// re-rings.
//
// `change` runs under the boards lock that builds both frames, so the reply
// describes the board it made active whatever another connection does next.
// When it returns false nothing is sent.
//
// Lock sequence: terms, term_boards, boards (each released before the next),
// then terms once per live term (the scrollback snapshot).
async fn change_and_send_active_board(
    daemon: &Daemon,
    conn: &mut AppConn,
    change: impl FnOnce(&mut Boards) -> bool,
) -> bool {
    let by_board = daemon.live_terms_by_board().await;
    let (board_list, restore, active_id, live_terms) = {
        let mut boards = daemon.boards.lock().await;
        if !change(&mut boards) {
            return false;
        }
        let active_id = boards.active_id().to_string();
        let live_terms = by_board.get(&active_id).cloned().unwrap_or_default();
        (
            boards.board_list_msg(&by_board),
            boards.active_restore_msg(live_terms.clone()),
            active_id,
            live_terms,
        )
    };
    let first = conn.replayed.insert(active_id);
    // Snapshot before sending the restore: a chunk produced after this is
    // delivered live and arrives before the restore (FIFO) while the term is
    // still unbound app-side, so the app drops it — replay + live never dup.
    let replay = if first { snapshot_scrollback(daemon, &live_terms).await } else { Vec::new() };
    let _ = conn.tx.send(board_list).await;
    let _ = conn.tx.send(restore).await;
    for (tid, data) in replay {
        for chunk in data.chunks(term::OUTPUT_CHUNK) {
            let _ = conn.tx.send(Msg::Output { term_id: tid.clone(), bytes: chunk.to_vec() }).await;
        }
    }
    true
}

async fn app_session(
    daemon: Arc<Daemon>,
    stream: UnixStream,
    app_version: Option<String>,
) -> anyhow::Result<()> {
    let (mut rd, mut wr) = stream.into_split();
    let (tx, mut rx) = mpsc::channel::<Msg>(256);
    let (generation, cancel) = daemon.install_app(tx.clone(), app_version).await;
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

    let mut conn = AppConn { tx, replayed: HashSet::new() };
    send_active_board(&daemon, &mut conn).await;

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
        Msg::SpawnTerm { term_id, cols, rows, cwd, cmd, board_id, inherit_cwd_from } => {
            let board = owning_board(daemon, board_id).await;
            let cwd = spawn_cwd(daemon, cwd, inherit_cwd_from).await;
            spawn_term(daemon, term_id, cols, rows, cwd, cmd, board).await;
        }
        Msg::Input { term_id, bytes } => match daemon.term(&term_id).await {
            Some(h) => {
                let _ = h.input_tx.send(bytes).await;
            }
            None => debug!("input for unknown term {term_id}"),
        },
        Msg::Resize { term_id, cols, rows } => match daemon.term(&term_id).await {
            Some(h) => {
                if let Err(e) = h.resize(cols, rows) {
                    warn!("{e}");
                }
            }
            None => debug!("resize for unknown term {term_id}"),
        },
        // Kills one terminal's process group (SIGHUP) so a single card can close.
        // The handle is cloned and the terms lock dropped before kill(), as in
        // board delete; the pump's wait thread then runs the normal exit cleanup.
        Msg::TermClose { term_id } => match daemon.term(&term_id).await {
            Some(h) => h.kill(),
            None => debug!("term_close for unknown term {term_id}"),
        },
        Msg::Open { path, term_id, board_id } => {
            // No reply frame for an app open; doc_opened is still pushed.
            if let Err(e) = docs::handle_open(daemon, &path, "user", term_id, board_id).await {
                daemon.push(Msg::Err { msg: e }).await;
            }
        }
        Msg::DocRead { path } => {
            // Fire-and-forget and idempotent; an unknown path is not an error.
            if daemon.boards.lock().await.active_registry_mut().mark_read(Path::new(&path)) {
                daemon.mark_dirty();
            } else {
                debug!("doc_read for unknown path {path}");
            }
        }
        Msg::Layout { dock, tiles, board, board_id } => {
            daemon
                .boards
                .lock()
                .await
                .registry_mut(board_id.as_deref())
                .apply_layout(dock, tiles, board);
            daemon.mark_dirty();
        }
        // mark_dirty runs inside `change`, before any frame is queued: a send
        // can wait on a slow reader, and the save must not wait with it.
        Msg::BoardSwitch { board_id } => {
            let switch = |b: &mut Boards| {
                let known = b.set_active(&board_id);
                if known {
                    daemon.mark_dirty();
                }
                known
            };
            if !change_and_send_active_board(daemon, conn, switch).await {
                debug!("board_switch to unknown board {board_id}");
            }
        }
        Msg::BoardCreate => {
            let create = |b: &mut Boards| {
                b.create();
                daemon.mark_dirty();
                true
            };
            change_and_send_active_board(daemon, conn, create).await;
        }
        Msg::BoardRename { board_id, name } => {
            // An empty name clears it. The boards lock is released before the
            // board_list re-push, which locks it again after the term maps.
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
        Msg::BoardDelete { board_id } => delete_board(daemon, conn, &board_id).await,
        Msg::DocClose { path } => {
            if !daemon.close_doc(Path::new(&path)).await {
                debug!("doc_close for unknown path {path}");
            }
        }
        Msg::DocRefresh { path } => {
            if !docs::stat_and_push(daemon, Path::new(&path)).await {
                debug!("doc_refresh no-op for {path} (not on the active board, or unreadable)");
            }
        }
        Msg::ScrollbackRequest { term_id } => {
            // `conn.replayed` is deliberately neither read nor written here: the
            // per-board one-time replay is a separate guarantee.
            let bytes = daemon.term(&term_id).await.map(|h| h.scrollback_snapshot()).unwrap_or_default();
            let _ = conn.tx.send(Msg::Scrollback { term_id, bytes }).await;
        }
        Msg::Unknown => debug!("ignoring unknown message type from app"),
        other => debug!("ignoring unexpected app message: {other:?}"),
    }
}

// An explicit, known board_id wins, else the active board.
async fn owning_board(daemon: &Daemon, board_id: Option<String>) -> BoardId {
    let boards = daemon.boards.lock().await;
    board_id
        .filter(|id| boards.contains(id))
        .unwrap_or_else(|| boards.active_id().to_string())
}

// A new terminal inherits its source's LIVE cwd, not its spawn cwd. An explicit
// `cwd` always wins; an unknown/dead source (or an OS lookup failure) falls
// through to term::spawn's own $HOME default — never an error.
async fn spawn_cwd(
    daemon: &Daemon,
    cwd: Option<String>,
    inherit_cwd_from: Option<String>,
) -> Option<String> {
    if cwd.is_some() {
        return cwd;
    }
    daemon.term(&inherit_cwd_from?).await?.live_cwd()
}

// No board_list re-push on a successful spawn: the app initiated it for a board
// it is building and already knows the new running count. Only the exit re-push
// (term.rs) is load-bearing, for a term dying on a board the app has not rebuilt.
async fn spawn_term(
    daemon: &Arc<Daemon>,
    term_id: String,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
    cmd: Option<Vec<String>>,
    board: BoardId,
) {
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

async fn delete_board(daemon: &Arc<Daemon>, conn: &mut AppConn, board_id: &str) {
    // Refuse early, killing nothing, when the board can't be deleted — the last
    // board or an unknown id; delete() re-checks authoritatively.
    let deletable = {
        let boards = daemon.boards.lock().await;
        boards.contains(board_id) && boards.iter().count() > 1
    };
    if !deletable {
        debug!("board_delete refused for {board_id} (last board or unknown)");
        return;
    }
    // Lock discipline: each map is locked alone and dropped before the next;
    // kill runs with NO lock held; std::sync::Mutex never spans an await.
    // 1) snapshot the board's term_ids (term_boards).
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
    // 3) kill the groups with no lock held; each pump's wait thread then runs
    //    the normal exit cleanup (terms/term_boards removal, Exit + board_list
    //    push). This path never touches those maps.
    for h in &handles {
        h.kill();
    }
    // 4) remove the board (active is fixed if it was the active one).
    if daemon.delete_board(board_id).await {
        // 5) re-push board_list + the now-active board's restore: the app needs
        //    the list either way, and a restore when the active board changed.
        send_active_board(daemon, conn).await;
    }
}
