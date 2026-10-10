use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{DebounceEventResult, Debouncer, RecommendedCache, new_debouncer};
use tarmac_protocol::{DocEntry, Msg};
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
    /// The registered docs in each directory, one for each board that has the
    /// doc. A directory is watched from its first doc to its last.
    doc_counts: HashMap<PathBuf, usize>,
    /// Not every counted directory: one that could not be watched has a count
    /// and no watch.
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
        // Every board's docs, so a backgrounded board's docs still report file
        // events.
        let doc_dirs: Vec<PathBuf> = boards
            .iter()
            .flat_map(|b| b.registry.docs.keys())
            .filter_map(|p| p.parent().map(Path::to_path_buf))
            .collect();
        let daemon = Arc::new(Daemon {
            app: Mutex::new(None),
            boards: Mutex::new(boards),
            terms: Mutex::new(HashMap::new()),
            term_boards: Mutex::new(HashMap::new()),
            watcher: std::sync::Mutex::new(WatcherState {
                debouncer,
                doc_counts: HashMap::new(),
                watched_dirs: HashSet::new(),
            }),
            next_generation: AtomicU64::new(1),
            dirty: Notify::new(),
            state_path,
        });
        // A vanished parent dir only loses file events; the doc keeps its dock slot.
        for dir in doc_dirs {
            if let Err(e) = daemon.acquire_watch(&dir) {
                tracing::warn!("cannot rewatch {}: {e}", dir.display());
            }
        }
        tokio::spawn(crate::docs::watch_loop(daemon.clone(), rx));
        tokio::spawn(crate::persist::save_loop(daemon.clone()));
        Ok(daemon)
    }

    /// Counts one more registered doc in `dir` and watches the directory if it
    /// is not watched yet. The count stands when the watch fails, so each call
    /// is paired with one `release_watch`.
    fn acquire_watch(&self, dir: &Path) -> anyhow::Result<()> {
        let mut w = self.watcher.lock().expect("watcher lock");
        *w.doc_counts.entry(dir.to_owned()).or_default() += 1;
        if w.watched_dirs.contains(dir) {
            return Ok(());
        }
        w.debouncer.watch(dir, RecursiveMode::NonRecursive)?;
        w.watched_dirs.insert(dir.to_owned());
        Ok(())
    }

    /// Takes one registered doc off the count of `dir`, and drops the watch
    /// with the last one.
    fn release_watch(&self, dir: &Path) {
        let mut w = self.watcher.lock().expect("watcher lock");
        let Some(count) = w.doc_counts.get_mut(dir) else { return };
        *count -= 1;
        if *count > 0 {
            return;
        }
        w.doc_counts.remove(dir);
        if w.watched_dirs.remove(dir) {
            if let Err(e) = w.debouncer.unwatch(dir) {
                tracing::warn!("unwatch {}: {e}", dir.display());
            }
        }
    }

    /// Registers a doc on `board` (the active one for `None`), or refreshes the
    /// one already there. Fails, with nothing registered, when its directory
    /// cannot be watched.
    pub async fn open_doc(
        &self,
        board: Option<&str>,
        path: &Path,
        via: &str,
        term_id: Option<String>,
    ) -> anyhow::Result<DocEntry> {
        let Some(dir) = path.parent() else {
            anyhow::bail!("path has no parent directory: {}", path.display());
        };
        // Counted before the doc is registered: a close that runs between the
        // two steps then finds a count above zero and keeps the watch.
        if let Err(e) = self.acquire_watch(dir) {
            self.release_watch(dir);
            anyhow::bail!("cannot watch {}: {e}", dir.display());
        }
        // Upsert before the entry is read so it reflects the post-open state.
        let (entry, is_new) = {
            let mut boards = self.boards.lock().await;
            let reg = boards.registry_mut(board);
            let is_new = crate::docs::upsert_doc(reg, path, via, term_id);
            (reg.entry(path).expect("doc just upserted"), is_new)
        };
        if !is_new {
            self.release_watch(dir);
        }
        self.mark_dirty();
        Ok(entry)
    }

    /// Forgets a doc of the active board and takes it off its directory's
    /// count. False for an unknown path.
    pub async fn close_doc(&self, path: &Path) -> bool {
        let closed = self.boards.lock().await.active_registry_mut().close_doc(path);
        if !closed {
            return false;
        }
        self.mark_dirty();
        if let Some(dir) = path.parent() {
            self.release_watch(dir);
        }
        true
    }

    /// Removes a board and takes its docs off their directories' counts. False
    /// for the last board or an unknown id.
    pub async fn delete_board(&self, id: &str) -> bool {
        let deleted = self.boards.lock().await.delete(id);
        let Some(board) = deleted else { return false };
        self.mark_dirty();
        for dir in board.registry.docs.keys().filter_map(|p| p.parent()) {
            self.release_watch(dir);
        }
        true
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

    fn daemon_with_doc_dir(tag: &str) -> (PathBuf, PathBuf, Arc<Daemon>) {
        let tmp = tmp_dir(tag);
        let doc_dir = tmp.join("d");
        std::fs::create_dir_all(&doc_dir).unwrap();
        let daemon = Daemon::new(tmp.join("state.json")).unwrap();
        (tmp, doc_dir, daemon)
    }

    async fn open_doc(daemon: &Daemon, board: Option<&str>, doc: &Path) {
        daemon.open_doc(board, doc, "t", None).await.unwrap();
    }

    fn watched(daemon: &Daemon, dir: &Path) -> bool {
        daemon.watcher.lock().unwrap().watched_dirs.contains(dir)
    }

    #[tokio::test]
    async fn a_dir_is_watched_from_its_first_count_to_its_last() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("count");

        daemon.acquire_watch(&doc_dir).unwrap();
        daemon.acquire_watch(&doc_dir).unwrap();
        assert!(watched(&daemon, &doc_dir));

        daemon.release_watch(&doc_dir);
        assert!(watched(&daemon, &doc_dir), "one doc is left");
        daemon.release_watch(&doc_dir);
        assert!(!watched(&daemon, &doc_dir));

        let _ = std::fs::remove_dir_all(&tmp);
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

    #[tokio::test]
    async fn deleting_a_board_unwatches_the_dirs_only_it_used() {
        let (tmp, shared, daemon) = daemon_with_doc_dir("delete-board");
        let own = tmp.join("own");
        std::fs::create_dir_all(&own).unwrap();
        open_doc(&daemon, None, &shared.join("a.md")).await;
        let other = daemon.boards.lock().await.create();
        open_doc(&daemon, Some(&other), &shared.join("b.md")).await;
        open_doc(&daemon, Some(&other), &own.join("c.md")).await;
        open_doc(&daemon, Some(&other), &own.join("d.md")).await;

        assert!(daemon.delete_board(&other).await);
        assert!(!watched(&daemon, &own), "no board has a doc in the directory");
        assert!(watched(&daemon, &shared), "board-0 still has a doc in the directory");
        assert!(!daemon.delete_board(&other).await, "a second delete finds no board");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn reopening_a_doc_counts_it_once() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("reopen");
        let doc = doc_dir.join("a.md");
        open_doc(&daemon, None, &doc).await;
        open_doc(&daemon, None, &doc).await;

        assert!(daemon.close_doc(&doc).await);
        assert!(!watched(&daemon, &doc_dir));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn an_open_that_cannot_watch_registers_and_counts_nothing() {
        let (tmp, _, daemon) = daemon_with_doc_dir("open-fails");
        let late_dir = tmp.join("late");
        let doc = late_dir.join("a.md");

        assert!(daemon.open_doc(None, &doc, "t", None).await.is_err(), "the directory does not exist");
        assert!(!daemon.close_doc(&doc).await, "nothing was registered");

        std::fs::create_dir_all(&late_dir).unwrap();
        open_doc(&daemon, None, &doc).await;
        assert!(daemon.close_doc(&doc).await);
        assert!(!watched(&daemon, &late_dir), "the failed open left no count");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    fn state_with_docs(docs: &[&Path]) -> String {
        let docs: Vec<_> = docs
            .iter()
            .map(|p| serde_json::json!({"path": p, "via": "cli", "read": false}))
            .collect();
        serde_json::json!({"boards": [{"board_id": "board-0", "docs": docs}]}).to_string()
    }

    #[tokio::test]
    async fn a_restart_counts_every_restored_doc() {
        let tmp = tmp_dir("restart-count");
        let doc_dir = tmp.join("d");
        std::fs::create_dir_all(&doc_dir).unwrap();
        let (a, b) = (doc_dir.join("a.md"), doc_dir.join("b.md"));
        std::fs::write(tmp.join("state.json"), state_with_docs(&[&a, &b])).unwrap();
        let daemon = Daemon::new(tmp.join("state.json")).unwrap();
        assert!(watched(&daemon, &doc_dir));

        assert!(daemon.close_doc(&a).await);
        assert!(watched(&daemon, &doc_dir), "b.md is left");
        assert!(daemon.close_doc(&b).await);
        assert!(!watched(&daemon, &doc_dir));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A directory that is gone at the start cannot be watched, but its doc is
    // still registered: it must hold the watch that a later open starts.
    #[tokio::test]
    async fn a_restored_doc_counts_when_its_dir_could_not_be_watched() {
        let tmp = tmp_dir("restart-missing");
        let doc_dir = tmp.join("d");
        let (a, b) = (doc_dir.join("a.md"), doc_dir.join("b.md"));
        std::fs::write(tmp.join("state.json"), state_with_docs(&[&a])).unwrap();
        let daemon = Daemon::new(tmp.join("state.json")).unwrap();
        assert!(!watched(&daemon, &doc_dir));

        std::fs::create_dir_all(&doc_dir).unwrap();
        open_doc(&daemon, None, &b).await;
        assert!(watched(&daemon, &doc_dir));
        assert!(daemon.close_doc(&b).await);
        assert!(watched(&daemon, &doc_dir), "a.md is left");
        assert!(daemon.close_doc(&a).await);
        assert!(!watched(&daemon, &doc_dir));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    async fn cli_open(daemon: &Arc<Daemon>, doc: &Path) {
        crate::docs::handle_open(daemon, doc.to_str().unwrap(), "cli", None, None).await.unwrap();
    }

    // #248: an open and a close in one directory, in whatever order the
    // scheduler gives. Nothing is delayed; without the count, about one round in
    // seven left the new doc registered and its directory unwatched.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn dir_stays_watched_when_an_open_races_a_close() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("open-races-close");
        // An open registers the canonical path (/tmp -> /private/tmp).
        let doc_dir = std::fs::canonicalize(&doc_dir).unwrap();
        let (a, b) = (doc_dir.join("a.md"), doc_dir.join("b.md"));
        std::fs::write(&a, "a").unwrap();
        std::fs::write(&b, "b").unwrap();

        for round in 0..100 {
            cli_open(&daemon, &a).await;
            let opening = tokio::spawn({
                let (daemon, b) = (daemon.clone(), b.clone());
                async move { cli_open(&daemon, &b).await }
            });
            let closing = tokio::spawn({
                let (daemon, a) = (daemon.clone(), a.clone());
                async move { daemon.close_doc(&a).await }
            });
            opening.await.unwrap();
            assert!(closing.await.unwrap());
            assert!(watched(&daemon, &doc_dir), "round {round}: b.md is registered");

            assert!(daemon.close_doc(&b).await);
            assert!(!watched(&daemon, &doc_dir), "round {round}: no doc is left");
        }

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
