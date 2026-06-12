use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use notify_debouncer_full::DebounceEventResult;
use tarmac_protocol::Msg;
use tokio::sync::mpsc::UnboundedReceiver;
use tracing::{debug, warn};

use crate::state::{Daemon, DocInfo};

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

    daemon.docs.lock().await.insert(
        canon.clone(),
        DocInfo { via: via.to_owned(), last_changed_ms: None },
    );
    debug!("doc opened via {via}: {}", canon.display());
    daemon
        .push(Msg::DocOpened {
            path: canon.to_string_lossy().into_owned(),
            via: via.to_owned(),
        })
        .await;
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
            let docs = daemon.docs.lock().await;
            for ev in &events {
                for p in &ev.paths {
                    if docs.contains_key(p.as_path()) {
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
            if let Some(info) = daemon.docs.lock().await.get_mut(&path) {
                info.last_changed_ms = Some(mtime_ms);
            }
            daemon
                .push(Msg::FileEvent { path: path.to_string_lossy().into_owned(), mtime_ms })
                .await;
        }
    }
}
