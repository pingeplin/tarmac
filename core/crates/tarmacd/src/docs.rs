use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use notify_debouncer_full::DebounceEventResult;
use tarmac_protocol::Msg;
use tokio::sync::mpsc::UnboundedReceiver;
use tracing::{debug, warn};

use crate::boards::DocInfo;
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

fn epoch_ms(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
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
    let parent = canon
        .parent()
        .ok_or_else(|| format!("path has no parent directory: {}", canon.display()))?;
    daemon
        .ensure_watched(parent)
        .map_err(|e| format!("cannot watch {}: {e}", parent.display()))?;

    // `None` resolves to the active board inside `registry_mut`.
    let target = match (board_id, &term_id) {
        (Some(id), _) => Some(id),
        (None, Some(t)) => daemon.term_boards.lock().await.get(t).cloned(),
        (None, None) => None,
    };

    // Upsert before pushing so the doc_opened entry reflects the post-open state.
    let entry = {
        let mut boards = daemon.boards.lock().await;
        let reg = boards.registry_mut(target.as_deref());
        match reg.docs.get_mut(&canon) {
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
                    info.term_id = term_id.clone();
                }
            }
            None => {
                let repo = derive_repo(&canon);
                reg.docs.insert(
                    canon.clone(),
                    DocInfo {
                        via: via.to_owned(),
                        read: via != "cli",
                        repo: repo.as_ref().map(|r| r.name.clone()),
                        repo_root: repo.as_ref().map(|r| r.root.clone()),
                        repo_color: repo.as_ref().map(|r| r.color),
                        last_changed_ms: None,
                        last_opened_ms: epoch_ms(SystemTime::now()),
                        term_id: term_id.clone(),
                    },
                );
                reg.dock.push(canon.clone());
            }
        }
        reg.entry(&canon).expect("doc just upserted")
    };
    daemon.mark_dirty();
    debug!("doc opened via {via}: {}", canon.display());
    daemon.push(Msg::DocOpened(entry)).await;
    Ok(())
}

pub async fn watch_loop(daemon: Arc<Daemon>, mut rx: UnboundedReceiver<DebounceEventResult>) {
    while let Some(res) = rx.recv().await {
        let events = match res {
            Ok(events) => events,
            Err(errors) => {
                warn!("watch errors: {errors:?}");
                continue;
            }
        };
        // Filter by path only, never by event kind: atomic replaces show up
        // as Create/Rename and must still count.
        let mut hits: HashSet<PathBuf> = HashSet::new();
        {
            let boards = daemon.boards.lock().await;
            let reg = boards.active_registry();
            for ev in &events {
                for p in &ev.paths {
                    if reg.docs.contains_key(p.as_path()) {
                        hits.insert(p.clone());
                    }
                }
            }
        }
        for path in hits {
            stat_and_push(&daemon, &path).await;
        }
    }
}

/// Stat `path` and, if it is a doc on the ACTIVE board, record the real mtime and
/// push `file_event`. Returns whether it pushed.
///
/// The sole producer of `Msg::FileEvent`: the notify watcher and the on-demand
/// `doc_refresh` share it, so the always-push rule (the mtime goes out changed
/// or not — "did anything change" is answered app-side by value) and the
/// active-board scoping are defined once. The registry lookup doubles as that
/// scoping check, which is why an unknown path costs one lock and no push.
pub async fn stat_and_push(daemon: &Arc<Daemon>, path: &Path) -> bool {
    // Deleted files emit nothing until the path exists again.
    let Ok(meta) = std::fs::metadata(path) else { return false };
    let Ok(modified) = meta.modified() else { return false };
    let mtime_ms = epoch_ms(modified);
    // Registry update lands before the push so a crash between the two never
    // loses the fact.
    {
        let mut boards = daemon.boards.lock().await;
        let Some(info) = boards.active_registry_mut().docs.get_mut(path) else { return false };
        info.last_changed_ms = Some(mtime_ms);
    }
    daemon.mark_dirty();
    daemon
        .push(Msg::FileEvent { path: path.to_string_lossy().into_owned(), mtime_ms })
        .await;
    true
}
