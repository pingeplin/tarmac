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
            // P5: the Registry has no access to live ptys (those are global on
            // Daemon). The conn layer stamps the real live_terms before sending.
            live_terms: vec![],
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

    // Remove a doc from docs + dock. Returns (existed, should_unwatch), where
    // should_unwatch is true iff no sibling doc in the same parent dir remains.
    // The DocClose arm relies on this to decide whether to drop the notify watch.
    pub fn close_doc(&mut self, path: &Path) -> (bool, bool) {
        if self.docs.remove(path).is_some() {
            self.dock.retain(|p| p != path);
            let has_sibling =
                path.parent().map(|par| self.docs.keys().any(|k| k.parent() == Some(par))).unwrap_or(false);
            (true, !has_sibling)
        } else {
            (false, false)
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
    // P5: each meta carries the daemon's live-pty count for that board (from
    // `running`, default 0), so the switcher shows honest liveness even for a
    // board the app has never visited this session (e.g. a board whose shells
    // survived an app relaunch). Counts are passed in by the caller because the
    // terms live on `Daemon`, not `Boards` (see `Daemon::running_counts`).
    pub fn board_list_msg(&self, running: &HashMap<BoardId, u32>) -> Msg {
        Msg::BoardList {
            boards: self
                .boards
                .iter()
                .map(|b| BoardMeta {
                    board_id: b.id.clone(),
                    name: b.name.clone(),
                    running: Some(running.get(&b.id).copied().unwrap_or(0)),
                })
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
            Msg::Restore { docs, tiles, board, live_terms, .. } => {
                Some(Msg::Restore { docs, tiles, board, board_id: Some(b.id.clone()), live_terms })
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

    // P5.4: set a board's display name (`None`/empty clears it to the slug
    // fallback — the caller maps "" → None). false (no-op) if no such board.
    pub fn rename(&mut self, id: &str, name: Option<String>) -> bool {
        match self.boards.iter_mut().find(|b| b.id == id) {
            Some(b) => {
                b.name = name;
                true
            }
            None => false,
        }
    }

    // P5.4: remove a board. REFUSED (false) when it is the last board (a board
    // set is never empty) or the id is unknown. When the deleted board was active,
    // `active` is fixed to the board now occupying its index (clamped to the new
    // last), so `active` always names a live board. Returns true on a real delete.
    pub fn delete(&mut self, id: &str) -> bool {
        if self.boards.len() <= 1 {
            return false;
        }
        let Some(idx) = self.boards.iter().position(|b| b.id == id) else {
            return false;
        };
        let was_active = self.active == id;
        self.boards.remove(idx);
        if was_active {
            let new_idx = idx.min(self.boards.len() - 1);
            self.active = self.boards[new_idx].id.clone();
        }
        true
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

    // Remove the notify watch for `dir`. Symmetric with `ensure_watched`; only
    // called when no remaining registered doc shares the directory. The watcher
    // Mutex is a std::sync::Mutex and must never be held across an `.await`.
    pub fn unwatch(&self, dir: &Path) {
        let mut w = self.watcher.lock().expect("watcher lock");
        if !w.watched_dirs.contains(dir) {
            return;
        }
        if let Err(e) = w.debouncer.unwatch(dir) {
            tracing::warn!("unwatch {}: {e}", dir.display());
        }
        w.watched_dirs.remove(dir);
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

    // P5: live-pty count per board (term_boards ∩ terms — a term_boards entry is
    // only authoritative if the term is still in `terms`). Locks `terms` then
    // `term_boards` sequentially (each released before the next), so it never
    // holds two term locks at once and can't deadlock against the pump's
    // terms→term_boards exit cleanup (term.rs).
    pub async fn running_counts(&self) -> HashMap<BoardId, u32> {
        let live: HashSet<String> = self.terms.lock().await.keys().cloned().collect();
        let term_boards = self.term_boards.lock().await;
        let mut counts: HashMap<BoardId, u32> = HashMap::new();
        for (term_id, board_id) in term_boards.iter() {
            if live.contains(term_id) {
                *counts.entry(board_id.clone()).or_insert(0) += 1;
            }
        }
        counts
    }

    // P5: a board_list carrying honest per-board live-pty counts, for the
    // spawn/exit re-push sites that aren't already holding the boards lock to
    // build a paired restore. Computes counts first (terms/term_boards), then
    // takes the boards lock — all sequential, no nested term+board hold.
    pub async fn board_list_msg(&self) -> Msg {
        let running = self.running_counts().await;
        self.boards.lock().await.board_list_msg(&running)
    }

    // P5: the live term_ids the daemon owns per board (term_boards ∩ terms). The
    // connect/switch restore path uses this to both stamp Restore.live_terms (so
    // the app re-binds to running shells) and derive board_list running counts —
    // one lock pass instead of two. Same sequential discipline as running_counts.
    pub async fn live_terms_by_board(&self) -> HashMap<BoardId, Vec<String>> {
        let live: HashSet<String> = self.terms.lock().await.keys().cloned().collect();
        let term_boards = self.term_boards.lock().await;
        let mut by_board: HashMap<BoardId, Vec<String>> = HashMap::new();
        for (term_id, board_id) in term_boards.iter() {
            if live.contains(term_id) {
                by_board.entry(board_id.clone()).or_default().push(term_id.clone());
            }
        }
        by_board
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
    use std::sync::atomic::{AtomicU32, Ordering};

    // Per-test unique temp dir (process id + counter avoids collisions across
    // parallel test threads or reused PIDs).
    fn tmp_dir(tag: &str) -> std::path::PathBuf {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let d = std::env::temp_dir().join(format!("tarmac-state-{}-{}-{n}", std::process::id(), tag));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

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

    // P5.4: helper to find a board's name across the boards set.
    fn name_of<'a>(boards: &'a Boards, id: &str) -> Option<&'a str> {
        boards.iter().find(|b| b.id == id).and_then(|b| b.name.as_deref())
    }

    // P5.4 rename: sets a name, clears it (None), and is a no-op for an unknown id.
    #[test]
    fn rename_sets_and_clears_name() {
        let mut boards = Boards::single();
        assert!(boards.rename("board-0", Some("infra".into())));
        assert_eq!(name_of(&boards, "board-0"), Some("infra"));
        // Clearing (None) drops back to the slug fallback (no name).
        assert!(boards.rename("board-0", None));
        assert_eq!(name_of(&boards, "board-0"), None);
        // Unknown id → false, no-op.
        assert!(!boards.rename("board-404", Some("x".into())));
    }

    // P5.4 delete: the last board is refused so a board set is never empty.
    #[test]
    fn delete_refuses_last_board() {
        let mut boards = Boards::single();
        assert!(!boards.delete("board-0"), "the last board can't be deleted");
        assert_eq!(boards.iter().count(), 1, "board-0 is still present");
        assert_eq!(boards.active_id(), "board-0");
    }

    // P5.4 delete: removing a NON-active board leaves the active board unchanged.
    #[test]
    fn delete_non_active_keeps_active() {
        let mut boards = Boards::single();
        boards.create(); // board-1, now active
        boards.set_active("board-0");
        assert!(boards.delete("board-1"));
        let ids: Vec<&str> = boards.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["board-0"]);
        assert_eq!(boards.active_id(), "board-0", "active is untouched by a non-active delete");
    }

    // P5.4 delete: removing the ACTIVE board fixes `active` to a surviving board.
    #[test]
    fn delete_active_board_fixes_active() {
        let mut boards = Boards::single();
        boards.create(); // board-1, active
        assert_eq!(boards.active_id(), "board-1");
        assert!(boards.delete("board-1"));
        // active falls back to the board now at the deleted index (board-0).
        assert_eq!(boards.active_id(), "board-0");
        assert_eq!(boards.iter().count(), 1);
    }

    // P5.4 delete: an unknown id is a no-op (false), boards unchanged.
    #[test]
    fn delete_unknown_id_is_noop() {
        let mut boards = Boards::single();
        boards.create(); // board-1
        assert!(!boards.delete("board-404"));
        assert_eq!(boards.iter().count(), 2);
    }

    fn doc_info() -> DocInfo {
        DocInfo { via: "t".into(), read: false, repo: None, repo_root: None, repo_color: None, last_changed_ms: None, last_opened_ms: 0, term_id: None }
    }

    // close_doc removes the closed path from Registry.dock and reports it existed.
    #[test]
    fn doc_close_prunes_closed_path_from_dock() {
        let mut reg = Registry::empty();
        let doc = PathBuf::from("/tmp/s6/a.md");
        reg.docs.insert(doc.clone(), doc_info());
        reg.dock.push(doc.clone());
        assert!(reg.dock.contains(&doc));
        let (existed, _) = reg.close_doc(&doc);
        assert!(existed);
        assert!(!reg.dock.contains(&doc));
    }

    // unwatch() removes the dir from watched_dirs when the sole doc is closed.
    #[tokio::test]
    async fn unwatch_removes_dir_when_sole_occupant_closed() {
        let tmp = tmp_dir("s8a");
        let doc_dir = tmp.join("d");
        std::fs::create_dir_all(&doc_dir).unwrap();
        let daemon = Daemon::new(tmp.join("state.json")).unwrap();

        daemon.ensure_watched(&doc_dir).unwrap();
        assert!(daemon.watcher.lock().unwrap().watched_dirs.contains(&doc_dir));

        daemon.unwatch(&doc_dir);
        assert!(!daemon.watcher.lock().unwrap().watched_dirs.contains(&doc_dir));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // When a sibling doc shares the dir, unwatch is skipped and watched_dirs retains it.
    #[tokio::test]
    async fn watched_dir_kept_when_sibling_doc_remains() {
        let tmp = tmp_dir("s8b");
        let doc_dir = tmp.join("d");
        std::fs::create_dir_all(&doc_dir).unwrap();
        let daemon = Daemon::new(tmp.join("state.json")).unwrap();

        let doc_a = doc_dir.join("a.md");
        let doc_b = doc_dir.join("b.md");
        {
            let mut boards = daemon.boards.lock().await;
            let reg = boards.active_registry_mut();
            for d in [&doc_a, &doc_b] {
                reg.docs.insert(d.clone(), doc_info());
                reg.dock.push(d.clone());
            }
        }
        daemon.ensure_watched(&doc_dir).unwrap();

        let (_, should_unwatch) = {
            let mut boards = daemon.boards.lock().await;
            boards.active_registry_mut().close_doc(&doc_a)
        };
        assert!(!should_unwatch, "must not unwatch when sibling doc remains");
        // Mirror production: only unwatch when no sibling remains.
        if should_unwatch {
            daemon.unwatch(&doc_dir);
        }
        assert!(daemon.watcher.lock().unwrap().watched_dirs.contains(&doc_dir));

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
