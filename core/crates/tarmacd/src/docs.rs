use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
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
    Some(FileStamp { mtime: meta.modified().ok()?, len: meta.len(), inode: meta.ino() })
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
                    untold: false,
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

/// One look for each wake, `BURST` after it: a save shorter than that is read
/// when it is done, and a file that keeps changing is read each `BURST` while
/// it does (#258). A wake that comes during the wait or the look is kept for
/// the next one.
pub async fn watch_loop(daemon: Arc<Daemon>) {
    loop {
        daemon.woken().await;
        tokio::time::sleep(crate::watch::BURST).await;
        report_changes(&daemon).await;
    }
}

/// What a look has for the app: the docs of `reg` whose file changed
/// (`Registry::take_changes`), then those whose last change reached no app. It
/// asks for the save of what it recorded: before any push, so a crash between
/// the two never loses the fact.
pub fn take_to_tell(
    daemon: &Daemon,
    reg: &mut Registry,
    now: &HashMap<PathBuf, Option<FileStamp>>,
) -> Vec<(PathBuf, u64)> {
    let mut tell = reg.take_changes(now);
    if !tell.is_empty() {
        daemon.mark_dirty();
    }
    tell.extend(reg.take_untold());
    tell
}

/// Compares each doc of the active board with its file, and pushes a
/// `file_event` for each that changed. A doc of another board is compared when
/// its board is sent (`conn::change_and_send_active_board`).
pub async fn report_changes(daemon: &Daemon) {
    let (board, tell) = daemon
        .look(
            |boards| boards.active_registry().docs.keys().cloned().collect::<Vec<_>>(),
            |boards, now| {
                let tell = take_to_tell(daemon, boards.active_registry_mut(), now);
                (boards.active_id().to_string(), tell)
            },
        )
        .await;
    for (path, mtime_ms) in tell {
        push_file_event(daemon, &board, &path, mtime_ms).await;
    }
}

pub fn file_event(path: &Path, mtime_ms: u64) -> Msg {
    Msg::FileEvent { path: path.to_string_lossy().into_owned(), mtime_ms }
}

/// Pushes the `file_event`, and holds the doc when it reached no app. `board`
/// is the board the change was taken for, which need not be active any more.
pub async fn push_file_event(daemon: &Daemon, board: &str, path: &Path, mtime_ms: u64) {
    if !daemon.push(file_event(path, mtime_ms)).await {
        daemon.boards.lock().await.hold(board, path);
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
    let recorded = daemon
        .look(
            |_| vec![path.to_owned()],
            |boards, now| {
                // Deleted files emit nothing until the path exists again.
                let stamp = now.get(path).copied().flatten()?;
                let mtime_ms = boards.active_registry_mut().refresh(path, stamp)?;
                // Before the push, as in `take_to_tell`.
                daemon.mark_dirty();
                Some((boards.active_id().to_string(), mtime_ms))
            },
        )
        .await;
    let Some((board, mtime_ms)) = recorded else { return false };
    push_file_event(daemon, &board, path, mtime_ms).await;
    true
}
