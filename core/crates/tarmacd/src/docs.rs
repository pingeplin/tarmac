use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use notify_debouncer_full::DebounceEventResult;
use tarmac_protocol::Msg;
use tokio::sync::mpsc::UnboundedReceiver;
use tracing::{debug, warn};

use crate::state::{Daemon, DocInfo};

pub struct RepoInfo {
    pub name: String,
    pub root: String,
    pub color: u8,
}

// Walk parents toward / looking for a .git entry; a plain file counts too
// (worktrees and submodules use a gitfile). None ⇒ not in a repo; the wire
// carries nil and the app falls back to the parent-dir basename as in M0.
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

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// Single code path for CLI ("cli") and app ("user") opens.
pub async fn handle_open(daemon: &Arc<Daemon>, raw_path: &str, via: &str) -> Result<(), String> {
    let p = Path::new(raw_path);
    if !p.is_absolute() {
        return Err(format!("path is not absolute: {raw_path}"));
    }
    // Canonicalize daemon-side too: FSEvents reports resolved paths and the
    // registry key must match them (e.g. /tmp -> /private/tmp).
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

    // Upsert before pushing so the doc_opened entry reflects the post-open
    // state (docs/protocol.md "doc_opened").
    let entry = {
        let mut reg = daemon.registry.lock().await;
        match reg.docs.get_mut(&canon) {
            Some(info) => {
                info.via = via.to_owned();
                info.last_opened_ms = now_ms();
                // Only cli opens may clear read; a user re-open leaves it
                // (crib §2.1). The dock slot never moves on re-open.
                if via == "cli" {
                    info.read = false;
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
                        last_opened_ms: now_ms(),
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
            let reg = daemon.registry.lock().await;
            for ev in &events {
                for p in &ev.paths {
                    if reg.docs.contains_key(p.as_path()) {
                        hits.insert(p.clone());
                    }
                }
            }
        }
        for path in hits {
            // Deleted files emit nothing until the path exists again.
            let Ok(meta) = std::fs::metadata(&path) else { continue };
            let Ok(modified) = meta.modified() else { continue };
            let mtime_ms = modified
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            // Registry update lands before the push so a crash between the
            // two never loses the fact (crib §8 req 6).
            if let Some(info) = daemon.registry.lock().await.docs.get_mut(&path) {
                info.last_changed_ms = Some(mtime_ms);
            }
            daemon.mark_dirty();
            daemon
                .push(Msg::FileEvent { path: path.to_string_lossy().into_owned(), mtime_ms })
                .await;
        }
    }
}
