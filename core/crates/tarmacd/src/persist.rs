//! Durable daemon state (registry + dock order + tiles) as JSON on disk.
//! Contract per docs/protocol.md: a daemon restart followed by an app connect
//! must produce a restore indistinguishable from one without the restart.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tarmac_protocol::Tile;
use tracing::warn;

use crate::state::{Daemon, DocInfo, Registry};

const SAVE_DEBOUNCE: Duration = Duration::from_millis(150);

#[derive(Serialize, Deserialize)]
struct PersistedDoc {
    path: String,
    via: String,
    read: bool,
    last_changed_ms: Option<u64>,
    #[serde(default)]
    last_opened_ms: u64,
    // Written for inspectability but recomputed at load (crib §1.1: a .git
    // appearing or vanishing between runs is an observed fact).
    repo: Option<String>,
    repo_root: Option<String>,
    repo_color: Option<u8>,
}

// docs[] is in dock order.
#[derive(Serialize, Deserialize, Default)]
struct PersistedState {
    #[serde(default)]
    docs: Vec<PersistedDoc>,
    #[serde(default)]
    tiles: Vec<Tile>,
}

// Missing or unreadable/corrupt state is never fatal: log and start empty.
pub fn load(path: &Path) -> Registry {
    let state = match std::fs::read(path) {
        Ok(bytes) => match serde_json::from_slice::<PersistedState>(&bytes) {
            Ok(s) => s,
            Err(e) => {
                warn!("corrupt state file {} ({e}); starting empty", path.display());
                PersistedState::default()
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => PersistedState::default(),
        Err(e) => {
            warn!("cannot read state file {} ({e}); starting empty", path.display());
            PersistedState::default()
        }
    };
    let mut reg = Registry::empty();
    for d in state.docs {
        let path = PathBuf::from(&d.path);
        if reg.docs.contains_key(&path) {
            continue;
        }
        let repo = crate::docs::derive_repo(&path);
        reg.docs.insert(
            path.clone(),
            DocInfo {
                via: d.via,
                read: d.read,
                repo: repo.as_ref().map(|r| r.name.clone()),
                repo_root: repo.as_ref().map(|r| r.root.clone()),
                repo_color: repo.as_ref().map(|r| r.color),
                last_changed_ms: d.last_changed_ms,
                last_opened_ms: d.last_opened_ms,
            },
        );
        reg.dock.push(path);
    }
    reg.set_tiles(state.tiles);
    reg
}

fn snapshot(reg: &Registry) -> PersistedState {
    PersistedState {
        docs: reg
            .dock
            .iter()
            .filter_map(|p| {
                let info = reg.docs.get(p)?;
                Some(PersistedDoc {
                    path: p.to_string_lossy().into_owned(),
                    via: info.via.clone(),
                    read: info.read,
                    last_changed_ms: info.last_changed_ms,
                    last_opened_ms: info.last_opened_ms,
                    repo: info.repo.clone(),
                    repo_root: info.repo_root.clone(),
                    repo_color: info.repo_color,
                })
            })
            .collect(),
        tiles: reg.tiles.clone(),
    }
}

fn write_atomic(path: &Path, state: &PersistedState) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("state path has no parent: {}", path.display()))?;
    std::fs::create_dir_all(parent)?;
    let tmp = path.with_extension("json.tmp");
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(&serde_json::to_vec_pretty(state)?)?;
    // fsync before rename so a crash never swaps in a truncated file.
    f.sync_all()?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

// Dirty-flag + short sleep coalesces mutation bursts into one write.
pub async fn save_loop(daemon: Arc<Daemon>) {
    loop {
        daemon.dirty_notified().await;
        tokio::time::sleep(SAVE_DEBOUNCE).await;
        let state = {
            let reg = daemon.registry.lock().await;
            snapshot(&reg)
        };
        if let Err(e) = write_atomic(daemon.state_path(), &state) {
            warn!("state save failed: {e}");
        }
    }
}
