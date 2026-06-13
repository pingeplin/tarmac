use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{DebounceEventResult, Debouncer, RecommendedCache, new_debouncer};
use tarmac_protocol::{BoardViewport, DocEntry, Msg, Tile};
use tokio::sync::{Mutex, Notify, mpsc};
use tokio_util::sync::CancellationToken;

pub struct DocInfo {
    pub via: String,
    pub read: bool,
    pub repo: Option<String>,
    pub repo_root: Option<String>,
    pub repo_color: Option<u8>,
    pub last_changed_ms: Option<u64>,
    pub last_opened_ms: u64,
    // v4 Phase 3: the term that opened this doc (provenance + gravity owner);
    // None when opened without a TARMAC_TERM_ID (e.g. a bare CLI run).
    pub term_id: Option<String>,
}

pub fn term_tile() -> Tile {
    Tile {
        kind: "term".into(),
        path: None,
        x: None,
        y: None,
        w: None,
        h: None,
        z: None,
        loose: None,
        shelf: None,
    }
}

pub struct Registry {
    pub docs: HashMap<PathBuf, DocInfo>,
    // Dock order is insertion order; re-opens never move a doc and the dock
    // never shrinks in M1 (crib §5.1).
    pub dock: Vec<PathBuf>,
    pub tiles: Vec<Tile>,
    // v4 board viewport for this (single) strip; None until the app sends one
    // via a layout snapshot. Round-tripped through persist (crib §9).
    pub board: Option<BoardViewport>,
}

impl Registry {
    pub fn empty() -> Self {
        Registry { docs: HashMap::new(), dock: Vec::new(), tiles: vec![term_tile()], board: None }
    }

    pub fn entry(&self, path: &Path) -> Option<DocEntry> {
        let info = self.docs.get(path)?;
        Some(DocEntry {
            path: path.to_string_lossy().into_owned(),
            via: info.via.clone(),
            repo: info.repo.clone(),
            repo_root: info.repo_root.clone(),
            repo_color: info.repo_color,
            read: info.read,
            last_changed_ms: info.last_changed_ms,
            last_opened_ms: Some(info.last_opened_ms),
            term_id: info.term_id.clone(),
        })
    }

    pub fn restore_msg(&self) -> Msg {
        Msg::Restore {
            docs: self.dock.iter().filter_map(|p| self.entry(p)).collect(),
            tiles: self.tiles.clone(),
            board: self.board.clone(),
        }
    }

    // Merge per docs/protocol.md "layout": paths not in the registry are
    // dropped; registered docs missing from the snapshot keep their previous
    // relative order, appended at the end. The optional v4 board viewport is
    // last-writer-wins: a snapshot carrying one replaces the stored viewport,
    // a snapshot omitting it leaves the stored viewport untouched.
    pub fn apply_layout(&mut self, dock: Vec<String>, tiles: Vec<Tile>, board: Option<BoardViewport>) {
        let mut seen: HashSet<PathBuf> = HashSet::new();
        let mut order: Vec<PathBuf> = Vec::new();
        for p in dock {
            let p = PathBuf::from(p);
            if self.docs.contains_key(&p) && seen.insert(p.clone()) {
                order.push(p);
            }
        }
        for p in std::mem::take(&mut self.dock) {
            if seen.insert(p.clone()) {
                order.push(p);
            }
        }
        self.dock = order;
        self.set_tiles(tiles);
        if board.is_some() {
            self.board = board;
        }
    }

    pub fn set_tiles(&mut self, tiles: Vec<Tile>) {
        let mut kept: Vec<Tile> = Vec::new();
        let mut have_term = false;
        for t in tiles {
            match t.kind.as_str() {
                "term" if !have_term => {
                    have_term = true;
                    kept.push(t);
                }
                "doc" => {
                    if t.path.as_deref().is_some_and(|p| self.docs.contains_key(Path::new(p))) {
                        kept.push(t);
                    }
                }
                // Duplicate "term" or a kind from a newer protocol: skip the
                // tile, keep the rest (protocol rule).
                _ => {}
            }
        }
        // M1 restores always carry exactly one term tile.
        if !have_term {
            kept.insert(0, term_tile());
        }
        self.tiles = kept;
    }
}

pub struct AppSlot {
    pub generation: u64,
    pub tx: mpsc::Sender<Msg>,
    pub cancel: CancellationToken,
}

pub struct WatcherState {
    debouncer: Debouncer<RecommendedWatcher, RecommendedCache>,
    watched_dirs: HashSet<PathBuf>,
}

pub struct Daemon {
    pub app: Mutex<Option<AppSlot>>,
    pub registry: Mutex<Registry>,
    pub terms: Mutex<HashMap<String, Arc<crate::term::TermHandle>>>,
    watcher: std::sync::Mutex<WatcherState>,
    next_generation: AtomicU64,
    dirty: Notify,
    state_path: PathBuf,
}

impl Daemon {
    pub fn new(state_path: PathBuf) -> anyhow::Result<Arc<Self>> {
        let (tx, rx) = mpsc::unbounded_channel::<DebounceEventResult>();
        // 100 ms debounce per docs/protocol.md file-watching semantics.
        let debouncer = new_debouncer(Duration::from_millis(100), None, move |res| {
            let _ = tx.send(res);
        })?;
        let registry = crate::persist::load(&state_path);
        let watch_dirs: HashSet<PathBuf> = registry
            .dock
            .iter()
            .filter_map(|p| p.parent().map(Path::to_path_buf))
            .collect();
        let daemon = Arc::new(Daemon {
            app: Mutex::new(None),
            registry: Mutex::new(registry),
            terms: Mutex::new(HashMap::new()),
            watcher: std::sync::Mutex::new(WatcherState {
                debouncer,
                watched_dirs: HashSet::new(),
            }),
            next_generation: AtomicU64::new(1),
            dirty: Notify::new(),
            state_path,
        });
        // Watches restart eagerly at load; a vanished parent dir only loses
        // file events — the doc keeps its dock slot (no doc_removed in M1).
        for dir in watch_dirs {
            if let Err(e) = daemon.ensure_watched(&dir) {
                tracing::warn!("cannot rewatch {}: {e}", dir.display());
            }
        }
        tokio::spawn(crate::docs::watch_loop(daemon.clone(), rx));
        tokio::spawn(crate::persist::save_loop(daemon.clone()));
        Ok(daemon)
    }

    pub fn ensure_watched(&self, dir: &Path) -> anyhow::Result<()> {
        let mut w = self.watcher.lock().expect("watcher lock");
        if w.watched_dirs.contains(dir) {
            return Ok(());
        }
        w.debouncer.watch(dir, RecursiveMode::NonRecursive)?;
        w.watched_dirs.insert(dir.to_owned());
        Ok(())
    }

    pub fn mark_dirty(&self) {
        self.dirty.notify_one();
    }

    pub async fn dirty_notified(&self) {
        self.dirty.notified().await;
    }

    pub fn state_path(&self) -> &Path {
        &self.state_path
    }

    pub async fn install_app(&self, tx: mpsc::Sender<Msg>) -> (u64, CancellationToken) {
        let cancel = CancellationToken::new();
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        let old = self.app.lock().await.replace(AppSlot {
            generation,
            tx,
            cancel: cancel.clone(),
        });
        if let Some(old) = old {
            tracing::info!("replacing previous app connection");
            old.cancel.cancel();
        }
        (generation, cancel)
    }

    pub async fn remove_app(&self, generation: u64) {
        let mut slot = self.app.lock().await;
        if slot.as_ref().is_some_and(|s| s.generation == generation) {
            *slot = None;
        }
    }

    // Push to the connected app, if any; otherwise drop silently.
    pub async fn push(&self, msg: Msg) {
        let tx = self.app.lock().await.as_ref().map(|s| s.tx.clone());
        if let Some(tx) = tx {
            let _ = tx.send(msg).await;
        }
    }
}
