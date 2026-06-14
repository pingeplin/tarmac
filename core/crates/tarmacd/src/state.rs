use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{DebounceEventResult, Debouncer, RecommendedCache, new_debouncer};
use tarmac_protocol::{BoardMeta, BoardViewport, DocEntry, Msg, Tile};
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
        term_id: None,
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
            // M3 (additive): the legacy single board leaves board_id absent, so
            // the restore frame stays byte-identical until a second board exists.
            // P2 stamps the real id when restoring a switched/non-default board.
            board_id: None,
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
        // v4 Phase 5b: keep each terminal tile with a *distinct* term_id, so N
        // terminal cards persist distinct positions. A `None` term_id is the
        // legacy single-terminal slot, kept once. Duplicate ids are dropped.
        let mut seen_terms: HashSet<Option<String>> = HashSet::new();
        for t in tiles {
            match t.kind.as_str() {
                "term" => {
                    if seen_terms.insert(t.term_id.clone()) {
                        kept.push(t);
                    }
                }
                "doc" => {
                    if t.path.as_deref().is_some_and(|p| self.docs.contains_key(Path::new(p))) {
                        kept.push(t);
                    }
                }
                // A kind from a newer protocol: skip the tile, keep the rest
                // (protocol rule).
                _ => {}
            }
        }
        // M1 restores always carry exactly one term tile; an empty / term-less
        // layout gets the default single terminal so the board is never
        // term-less.
        if seen_terms.is_empty() {
            kept.insert(0, term_tile());
        }
        self.tiles = kept;
    }
}

// v4 M3 ("strips = boards"): a board is the unit that becomes N — today's
// single implicit board is just board-0. `BoardId` keys it; `name` is the
// user-given display name (None until named — manual naming only, decision
// 2026-06-13), the switcher falling back to the slug id.
pub type BoardId = String;
pub const DEFAULT_BOARD_ID: &str = "board-0";

pub struct Board {
    pub id: BoardId,
    pub name: Option<String>,
    pub registry: Registry,
}

impl Board {
    pub fn new(id: impl Into<BoardId>, registry: Registry) -> Self {
        Board { id: id.into(), name: None, registry }
    }
}

// The set of boards the daemon holds, in display order, with the active one.
// One coarse lock (matches the pre-M3 single-Registry mutex; N is single-digit).
// A `Vec` preserves ⌘1..9 order without a new dependency.
pub struct Boards {
    boards: Vec<Board>,
    active: BoardId,
}

impl Boards {
    // A fresh single board-0 (no persisted state) — the pre-M3 default.
    pub fn single() -> Self {
        Boards { boards: vec![Board::new(DEFAULT_BOARD_ID, Registry::empty())], active: DEFAULT_BOARD_ID.into() }
    }

    // Build from loaded boards, never board-less; an `active` that names no
    // board falls back to the first board.
    pub fn from_boards(boards: Vec<Board>, active: BoardId) -> Self {
        if boards.is_empty() {
            return Boards::single();
        }
        let active = if boards.iter().any(|b| b.id == active) {
            active
        } else {
            boards[0].id.clone()
        };
        Boards { boards, active }
    }

    pub fn active_id(&self) -> &str {
        &self.active
    }

    fn active_board(&self) -> &Board {
        self.boards.iter().find(|b| b.id == self.active).expect("active board present")
    }

    pub fn active_registry(&self) -> &Registry {
        &self.active_board().registry
    }

    pub fn active_registry_mut(&mut self) -> &mut Registry {
        let active = self.active.clone();
        self.registry_for_mut(&active)
    }

    // Registry for a board by id; an unknown id falls back to the active board.
    // P1 holds a single board, so callers always reach board-0; P2's board CRUD
    // makes the id authoritative.
    pub fn registry_for_mut(&mut self, id: &str) -> &mut Registry {
        let idx = self
            .boards
            .iter()
            .position(|b| b.id == id)
            .or_else(|| self.boards.iter().position(|b| b.id == self.active))
            .unwrap_or(0);
        &mut self.boards[idx].registry
    }

    // Registry for an optional wire board_id (None ⇒ active board).
    pub fn registry_for_opt_mut(&mut self, id: Option<&str>) -> &mut Registry {
        match id {
            Some(id) => self.registry_for_mut(id),
            None => self.active_registry_mut(),
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = &Board> {
        self.boards.iter()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.boards.iter().any(|b| b.id == id)
    }

    // M3 board_list: every board's identity in display order + the active id.
    pub fn board_list_msg(&self) -> Msg {
        Msg::BoardList {
            boards: self
                .boards
                .iter()
                .map(|b| BoardMeta { board_id: b.id.clone(), name: b.name.clone() })
                .collect(),
            active: self.active.clone(),
        }
    }

    // Restore for the active board (stamped with its id so the app binds it
    // unambiguously even across rapid switches).
    pub fn active_restore_msg(&self) -> Msg {
        self.restore_msg_for(&self.active.clone()).expect("active board present")
    }

    // Restore for a specific board, stamped with its id; None if no such board.
    pub fn restore_msg_for(&self, id: &str) -> Option<Msg> {
        let b = self.boards.iter().find(|b| b.id == id)?;
        match b.registry.restore_msg() {
            Msg::Restore { docs, tiles, board, .. } => {
                Some(Msg::Restore { docs, tiles, board, board_id: Some(b.id.clone()) })
            }
            _ => unreachable!("restore_msg always yields Restore"),
        }
    }

    // Make `id` active; false (no-op) if no such board.
    pub fn set_active(&mut self, id: &str) -> bool {
        if self.contains(id) {
            self.active = id.to_string();
            true
        } else {
            false
        }
    }

    // Mint a fresh board (slug `board-N`, N one past the max existing index) and
    // make it active. Returns the new board's id.
    pub fn create(&mut self) -> BoardId {
        let next = self
            .boards
            .iter()
            .filter_map(|b| b.id.strip_prefix("board-").and_then(|s| s.parse::<usize>().ok()))
            .max()
            .map(|m| m + 1)
            .unwrap_or(self.boards.len());
        let id = format!("board-{next}");
        self.boards.push(Board::new(id.clone(), Registry::empty()));
        self.active = id.clone();
        id
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
    // M3: N boards behind one coarse lock (was a single `Registry`); terms stay
    // global, keyed by their globally-unique term_id (board-agnostic).
    pub boards: Mutex<Boards>,
    pub terms: Mutex<HashMap<String, Arc<crate::term::TermHandle>>>,
    // M3: which board each terminal belongs to (set at spawn). Lets `tarmac
    // open` from a backgrounded board's term land its doc on the right board,
    // and (P5) scopes per-board teardown/restore. Keyed by the global term_id.
    pub term_boards: Mutex<HashMap<String, BoardId>>,
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
        let boards = crate::persist::load(&state_path);
        // Watch every board's dock dirs (the union), so a backgrounded board's
        // docs still report file events.
        let watch_dirs: HashSet<PathBuf> = boards
            .iter()
            .flat_map(|b| b.registry.dock.iter())
            .filter_map(|p| p.parent().map(Path::to_path_buf))
            .collect();
        let daemon = Arc::new(Daemon {
            app: Mutex::new(None),
            boards: Mutex::new(boards),
            terms: Mutex::new(HashMap::new()),
            term_boards: Mutex::new(HashMap::new()),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn term(id: Option<&str>) -> Tile {
        Tile { kind: "term".into(), term_id: id.map(str::to_string), ..term_tile() }
    }

    fn terms_kept(r: &Registry) -> Vec<Option<String>> {
        r.tiles.iter().filter(|t| t.kind == "term").map(|t| t.term_id.clone()).collect()
    }

    // v4 Phase 5b: distinct term_ids each keep their own tile (N terminal cards
    // persist distinct positions), in order.
    #[test]
    fn set_tiles_keeps_distinct_term_ids() {
        let mut r = Registry::empty();
        r.set_tiles(vec![term(Some("t1")), term(Some("t2"))]);
        assert_eq!(terms_kept(&r), vec![Some("t1".into()), Some("t2".into())]);
    }

    // A duplicate term_id (the app must never send these) is deduped to one.
    #[test]
    fn set_tiles_drops_duplicate_term_id() {
        let mut r = Registry::empty();
        r.set_tiles(vec![term(Some("t1")), term(Some("t1"))]);
        assert_eq!(terms_kept(&r), vec![Some("t1".into())]);
    }

    // A legacy single-terminal layout (term tile, no term_id) keeps exactly one
    // None-keyed slot — the Phase 5a / M1 shape is preserved.
    #[test]
    fn set_tiles_keeps_one_legacy_none_term() {
        let mut r = Registry::empty();
        r.set_tiles(vec![term(None), term(None)]);
        assert_eq!(terms_kept(&r), vec![None]);
    }

    // An empty / term-less layout still gets the default single terminal so the
    // board is never term-less (matches the pre-5b fallback).
    #[test]
    fn set_tiles_empty_inserts_default_terminal() {
        let mut r = Registry::empty();
        r.set_tiles(vec![]);
        assert_eq!(r.tiles, vec![term_tile()]);
    }
}
