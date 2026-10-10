use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{DebounceEventResult, Debouncer, RecommendedCache, new_debouncer};
use tarmac_protocol::Msg;
use tokio::sync::{Mutex, Notify, mpsc};
use tokio_util::sync::CancellationToken;

use crate::boards::{BoardId, Boards};
use crate::term::TermHandle;

pub struct AppSlot {
    pub generation: u64,
    pub tx: mpsc::Sender<Msg>,
    pub cancel: CancellationToken,
    /// What the app reported in its `hello`. `None` means the app connected
    /// without naming a version, which is NOT the same as no app — slot
    /// occupancy is the separate fact `app_slot_version` reports first.
    pub version: Option<String>,
}

pub struct WatcherState {
    debouncer: Debouncer<RecommendedWatcher, RecommendedCache>,
    watched_dirs: HashSet<PathBuf>,
}

pub struct Daemon {
    pub app: Mutex<Option<AppSlot>>,
    pub boards: Mutex<Boards>,
    /// Keyed by the globally-unique term_id, whatever board the term belongs to.
    pub terms: Mutex<HashMap<String, Arc<TermHandle>>>,
    /// The board each terminal belongs to (set at spawn): routes `tarmac open`
    /// from a backgrounded board's term and scopes per-board teardown/restore.
    pub term_boards: Mutex<HashMap<String, BoardId>>,
    /// A `std::sync::Mutex`, never held across an `.await`.
    watcher: std::sync::Mutex<WatcherState>,
    next_generation: AtomicU64,
    dirty: Notify,
    state_path: PathBuf,
}

impl Daemon {
    pub fn new(state_path: PathBuf) -> anyhow::Result<Arc<Self>> {
        let (tx, rx) = mpsc::unbounded_channel::<DebounceEventResult>();
        // 100 ms: the burst window docs/protocol.md gives a `file_event`.
        let debouncer = new_debouncer(Duration::from_millis(100), None, move |res| {
            let _ = tx.send(res);
        })?;
        let boards = crate::persist::load(&state_path);
        // The union of every board's dock dirs, so a backgrounded board's docs
        // still report file events.
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
        // A vanished parent dir only loses file events; the doc keeps its dock slot.
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

    /// Forgets a doc of the active board, and drops its directory's watch when
    /// no board has a doc left there. False for an unknown path.
    pub async fn close_doc(&self, path: &Path) -> bool {
        // The block releases the boards lock before any unwatch.
        let unused_dir = {
            let mut boards = self.boards.lock().await;
            if !boards.active_registry_mut().close_doc(path) {
                return false;
            }
            path.parent().filter(|dir| !boards.dir_in_use(dir))
        };
        self.mark_dirty();
        if let Some(dir) = unused_dir {
            self.unwatch(dir);
        }
        true
    }

    fn unwatch(&self, dir: &Path) {
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

    pub async fn install_app(
        &self,
        tx: mpsc::Sender<Msg>,
        version: Option<String>,
    ) -> (u64, CancellationToken) {
        let cancel = CancellationToken::new();
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        let old = self.app.lock().await.replace(AppSlot {
            generation,
            tx,
            cancel: cancel.clone(),
            version,
        });
        if let Some(old) = old {
            tracing::info!("replacing previous app connection");
            old.cancel.cancel();
        }
        (generation, cancel)
    }

    /// Slot occupancy and the version the occupant reported — see `AppSlot`.
    pub async fn app_slot_version(&self) -> (bool, Option<String>) {
        let slot = self.app.lock().await;
        match slot.as_ref() {
            Some(s) => (true, s.version.clone()),
            None => (false, None),
        }
    }

    pub async fn remove_app(&self, generation: u64) {
        let mut slot = self.app.lock().await;
        if slot.as_ref().is_some_and(|s| s.generation == generation) {
            *slot = None;
        }
    }

    pub async fn term(&self, id: &str) -> Option<Arc<TermHandle>> {
        self.terms.lock().await.get(id).cloned()
    }

    /// A board_list with live-pty counts, locking terms, term_boards, then
    /// boards — each released before the next is taken.
    pub async fn board_list_msg(&self) -> Msg {
        let live = self.live_terms_by_board().await;
        self.boards.lock().await.board_list_msg(&live)
    }

    /// The live term_ids per board (term_boards ∩ terms: an entry only counts
    /// while its term is still in `terms`). Locks `terms`, then `term_boards`,
    /// each released before the next, so it cannot deadlock against the pump's
    /// terms-then-term_boards exit cleanup.
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

    /// Pushes to the connected app; dropped silently when there is none.
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
    use crate::boards::DocInfo;
    use std::sync::atomic::{AtomicU32, Ordering};

    // Per-test unique temp dir (process id + counter avoids collisions across
    // parallel test threads or reused PIDs).
    fn tmp_dir(tag: &str) -> PathBuf {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let d = std::env::temp_dir().join(format!("tarmac-state-{}-{}-{n}", std::process::id(), tag));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn doc_info() -> DocInfo {
        DocInfo { via: "t".into(), read: false, repo: None, repo_root: None, repo_color: None, last_changed_ms: None, last_opened_ms: 0, term_id: None }
    }

    fn daemon_with_doc_dir(tag: &str) -> (PathBuf, PathBuf, Arc<Daemon>) {
        let tmp = tmp_dir(tag);
        let doc_dir = tmp.join("d");
        std::fs::create_dir_all(&doc_dir).unwrap();
        let daemon = Daemon::new(tmp.join("state.json")).unwrap();
        (tmp, doc_dir, daemon)
    }

    #[tokio::test]
    async fn unwatch_removes_dir_when_sole_occupant_closed() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("s8a");

        daemon.ensure_watched(&doc_dir).unwrap();
        assert!(daemon.watcher.lock().unwrap().watched_dirs.contains(&doc_dir));

        daemon.unwatch(&doc_dir);
        assert!(!daemon.watcher.lock().unwrap().watched_dirs.contains(&doc_dir));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// Watches the directory of `doc` and registers it on board `board`, as an
    /// open does.
    async fn open_doc(daemon: &Daemon, board: Option<&str>, doc: &Path) {
        daemon.ensure_watched(doc.parent().unwrap()).unwrap();
        let mut boards = daemon.boards.lock().await;
        let reg = boards.registry_mut(board);
        reg.docs.insert(doc.to_owned(), doc_info());
        reg.dock.push(doc.to_owned());
    }

    fn watched(daemon: &Daemon, dir: &Path) -> bool {
        daemon.watcher.lock().unwrap().watched_dirs.contains(dir)
    }

    #[tokio::test]
    async fn closing_the_sole_doc_of_a_dir_unwatches_it() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("close-sole");
        let doc = doc_dir.join("a.md");
        open_doc(&daemon, None, &doc).await;
        assert!(watched(&daemon, &doc_dir));

        assert!(daemon.close_doc(&doc).await);
        assert!(!watched(&daemon, &doc_dir));
        assert!(!daemon.close_doc(&doc).await, "a second close finds no doc");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn watched_dir_kept_when_sibling_doc_remains() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("s8b");
        let doc_a = doc_dir.join("a.md");
        open_doc(&daemon, None, &doc_a).await;
        open_doc(&daemon, None, &doc_dir.join("b.md")).await;

        assert!(daemon.close_doc(&doc_a).await);
        assert!(watched(&daemon, &doc_dir));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn watched_dir_kept_while_another_board_has_a_doc_there() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("close-cross-board");
        let (doc_a, doc_b) = (doc_dir.join("a.md"), doc_dir.join("b.md"));
        open_doc(&daemon, None, &doc_a).await;
        let other = daemon.boards.lock().await.create();
        open_doc(&daemon, Some(&other), &doc_b).await;

        assert!(daemon.close_doc(&doc_b).await);
        assert!(watched(&daemon, &doc_dir), "board-0 still has a doc in the directory");

        daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);
        assert!(daemon.close_doc(&doc_a).await);
        assert!(!watched(&daemon, &doc_dir), "no board has a doc in the directory");

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
