use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use tarmac_protocol::Msg;
use tracing::debug;

use crate::boards::{DocInfo, FileStamp, Registry, epoch_ms};
use crate::state::Daemon;

pub struct RepoInfo {
    pub name: String,
    pub root: String,
    pub color: u8,
}

// Walk parents toward / looking for a .git entry; a plain file counts too
// (worktrees and submodules use a gitfile). None means not in a repo.
pub fn derive_repo(doc: &Path) -> Option<RepoInfo> {
    let mut dir = doc.parent();
    while let Some(d) = dir {
        if d.join(".git").exists() {
            let name = d.file_name()?.to_string_lossy().into_owned();
            return Some(RepoInfo {
                color: tarmac_protocol::repo_color_index(&name),
                root: d.to_string_lossy().into_owned(),
                name,
            });
        }
        dir = d.parent();
    }
    None
}

/// `None` for a file that is not there or cannot be read.
pub fn stamp(path: &Path) -> Option<FileStamp> {
    let meta = std::fs::metadata(path).ok()?;
    Some(FileStamp { mtime: meta.modified().ok()?, len: meta.len() })
}

// Single code path for CLI ("cli") and app ("user") opens. `term_id` is the
// calling terminal card, None when unknown. The doc lands on `board_id`, else
// the board owning the calling term, else the active board.
pub async fn handle_open(
    daemon: &Arc<Daemon>,
    raw_path: &str,
    via: &str,
    term_id: Option<String>,
    board_id: Option<String>,
) -> Result<(), String> {
    let p = Path::new(raw_path);
    if !p.is_absolute() {
        return Err(format!("path is not absolute: {raw_path}"));
    }
    // FSEvents reports resolved paths and the registry key must match them
    // (e.g. /tmp -> /private/tmp), so canonicalize daemon-side too.
    let canon =
        std::fs::canonicalize(p).map_err(|e| format!("cannot open {raw_path}: {e}"))?;
    let meta =
        std::fs::metadata(&canon).map_err(|e| format!("cannot stat {}: {e}", canon.display()))?;
    if !meta.is_file() {
        return Err(format!("not a regular file: {}", canon.display()));
    }
    // `None` resolves to the active board inside `registry_mut`.
    let target = match (board_id, &term_id) {
        (Some(id), _) => Some(id),
        (None, Some(t)) => daemon.term_boards.lock().await.get(t).cloned(),
        (None, None) => None,
    };
    let entry = daemon
        .open_doc(target.as_deref(), &canon, via, term_id)
        .await
        .map_err(|e| e.to_string())?;
    debug!("doc opened via {via}: {}", canon.display());
    daemon.push(Msg::DocOpened(entry)).await;
    Ok(())
}

/// Registers `path` in `reg`, or refreshes the doc already there. True when
/// the doc is new to `reg`; `seen` is then its file as it is now.
pub fn upsert_doc(
    reg: &mut Registry,
    path: &Path,
    via: &str,
    term_id: Option<String>,
    seen: Option<FileStamp>,
) -> bool {
    match reg.docs.get_mut(path) {
        Some(info) => {
            info.via = via.to_owned();
            info.last_opened_ms = epoch_ms(SystemTime::now());
            // Only cli opens may clear read; a user re-open leaves it. The
            // dock slot never moves on re-open. A re-open carrying a term_id
            // updates the provenance owner; one without keeps the prior owner.
            if via == "cli" {
                info.read = false;
            }
            if term_id.is_some() {
                info.term_id = term_id;
            }
            false
        }
        None => {
            let repo = derive_repo(path);
            reg.docs.insert(
                path.to_owned(),
                DocInfo {
                    via: via.to_owned(),
                    read: via != "cli",
                    repo: repo.as_ref().map(|r| r.name.clone()),
                    repo_root: repo.as_ref().map(|r| r.root.clone()),
                    repo_color: repo.as_ref().map(|r| r.color),
                    last_changed_ms: None,
                    seen,
                    last_opened_ms: epoch_ms(SystemTime::now()),
                    term_id,
                },
            );
            reg.dock.push(path.to_owned());
            true
        }
    }
}

pub fn stamps(paths: impl IntoIterator<Item = PathBuf>) -> HashMap<PathBuf, Option<FileStamp>> {
    paths
        .into_iter()
        .map(|path| {
            let stamp = stamp(&path);
            (path, stamp)
        })
        .collect()
}

/// One look for each wake, and `BURST` between two looks: a wake can come
/// from any file of a watched directory, in the middle of a doc's own burst.
pub async fn watch_loop(daemon: Arc<Daemon>) {
    loop {
        daemon.woken().await;
        report_changes(&daemon).await;
        tokio::time::sleep(crate::watch::BURST).await;
    }
}

/// Compares each doc of the active board with its file, and pushes a
/// `file_event` for each that changed (`Registry::take_changes`). The files are
/// read with no `boards` lock held. A doc of another board is compared when
/// its board is sent (`conn::change_and_send_active_board`).
///
/// With no app connected it only notes the change (`Registry::note_changes`):
/// what was seen is what an app was told, so the connect still finds the
/// change and reports it, and a restart before that keeps its time.
pub async fn report_changes(daemon: &Daemon) {
    let told = daemon.app_connected().await;
    let changes = {
        let _one_look = daemon.looking().await;
        let paths: Vec<PathBuf> = daemon.boards.lock().await.active_registry().docs.keys().cloned().collect();
        let now = stamps(paths);
        let mut boards = daemon.boards.lock().await;
        let reg = boards.active_registry_mut();
        if told {
            reg.take_changes(&now)
        } else {
            if reg.note_changes(&now) {
                daemon.mark_dirty();
            }
            Vec::new()
        }
    };
    if changes.is_empty() {
        return;
    }
    // Recorded before the push, as in `stat_and_push`.
    daemon.mark_dirty();
    for (path, mtime_ms) in changes {
        daemon.push(Msg::FileEvent { path: path.to_string_lossy().into_owned(), mtime_ms }).await;
    }
}

/// `doc_refresh`: stat `path` and, if it is a doc on the ACTIVE board, record
/// the mtime and push `file_event`. Returns whether it pushed.
///
/// It pushes always, with the mtime changed or not ("did anything change" is
/// answered app-side by value); `report_changes` pushes only for a file that
/// differs from what was seen. The registry lookup is also the active-board
/// check, which is why an unknown path costs one lock and no push.
pub async fn stat_and_push(daemon: &Arc<Daemon>, path: &Path) -> bool {
    let mtime_ms = {
        let _one_look = daemon.looking().await;
        // Deleted files emit nothing until the path exists again.
        let Some(stamp) = stamp(path) else { return false };
        // Registry update lands before the push so a crash between the two
        // never loses the fact.
        let mut boards = daemon.boards.lock().await;
        let Some(info) = boards.active_registry_mut().docs.get_mut(path) else { return false };
        info.seen = Some(stamp);
        let mtime_ms = epoch_ms(stamp.mtime);
        info.last_changed_ms = Some(mtime_ms);
        mtime_ms
    };
    daemon.mark_dirty();
    daemon
        .push(Msg::FileEvent { path: path.to_string_lossy().into_owned(), mtime_ms })
        .await;
    true
}
