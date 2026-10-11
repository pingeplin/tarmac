use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use tarmac_protocol::{DocEntry, Msg};
use tokio::sync::{Mutex, Notify, mpsc};
use tokio_util::sync::CancellationToken;

use crate::boards::{BoardId, Boards};
use crate::term::TermHandle;
use crate::watch::{NotifySource, WakeSource};

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
    source: Box<dyn WakeSource>,
    /// The registered docs in each directory, one for each board that has the
    /// doc. A directory is watched from its first doc on.
    doc_counts: HashMap<PathBuf, usize>,
    /// Not the counted directories exactly: one that could not be watched has
    /// a count and no watch, and one that a board delete emptied has a watch
    /// and no count.
    watched_dirs: HashSet<PathBuf>,
}

impl WatcherState {
    /// True when that was the last registered doc in `dir`.
    fn uncount(&mut self, dir: &Path) -> bool {
        let Some(count) = self.doc_counts.get_mut(dir) else { return false };
        *count -= 1;
        if *count > 0 {
            return false;
        }
        self.doc_counts.remove(dir);
        true
    }
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
    /// Set by the watcher; `docs::watch_loop` waits on it.
    wake: Arc<Notify>,
    /// Held from the read of the files to the `take_changes` that uses it, so
    /// that an older reading is never taken after a newer one. Taken before
    /// `boards`, never while `boards` is held.
    looking: Mutex<()>,
    next_generation: AtomicU64,
    dirty: Notify,
    state_path: PathBuf,
}

impl Daemon {
    pub fn new(state_path: PathBuf) -> anyhow::Result<Arc<Self>> {
        let wake = Arc::new(Notify::new());
        let source = NotifySource::new({
            let wake = wake.clone();
            move || wake.notify_one()
        })?;
        Ok(Self::with_source(state_path, Box::new(source), wake))
    }

    /// `source` is told which directories have a doc, and sets `wake` when a
    /// file in one of them may have changed.
    pub fn with_source(state_path: PathBuf, source: Box<dyn WakeSource>, wake: Arc<Notify>) -> Arc<Self> {
        let boards = crate::persist::load(&state_path);
        // Every board's docs, not the active board's only: a switch adds no
        // watch.
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
                source,
                doc_counts: HashMap::new(),
                watched_dirs: HashSet::new(),
            }),
            wake,
            looking: Mutex::new(()),
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
        tokio::spawn(crate::docs::watch_loop(daemon.clone()));
        tokio::spawn(crate::persist::save_loop(daemon.clone()));
        daemon
    }

    pub async fn woken(&self) {
        self.wake.notified().await;
    }

    pub async fn looking(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.looking.lock().await
    }

    pub async fn app_connected(&self) -> bool {
        self.app.lock().await.is_some()
    }

    /// The path of each registered doc, of every board.
    pub async fn doc_paths(&self) -> HashSet<PathBuf> {
        self.boards.lock().await.iter().flat_map(|b| b.registry.docs.keys().cloned()).collect()
    }

    /// Counts one more registered doc in `dir` and watches the directory if it
    /// is not watched yet: true when it did. The count stands when the watch
    /// fails, so each call is paired with one `release_watch` or
    /// `release_count`.
    ///
    /// A watch and an unwatch each restart the FSEvents stream, and the restart
    /// loses the events that the stream has not delivered yet (#253). So a
    /// caller that gets true looks at the docs itself (`docs::report_changes`).
    fn acquire_watch(&self, dir: &Path) -> anyhow::Result<bool> {
        let mut w = self.watcher.lock().expect("watcher lock");
        *w.doc_counts.entry(dir.to_owned()).or_default() += 1;
        if w.watched_dirs.contains(dir) {
            return Ok(false);
        }
        w.source.watch(dir)?;
        w.watched_dirs.insert(dir.to_owned());
        Ok(true)
    }

    /// Takes one registered doc off the count of `dir`, and drops the watch
    /// with the last one: true when it did (see `acquire_watch`).
    fn release_watch(&self, dir: &Path) -> bool {
        let mut w = self.watcher.lock().expect("watcher lock");
        let unwatch = w.uncount(dir) && w.watched_dirs.remove(dir);
        if unwatch {
            if let Err(e) = w.source.unwatch(dir) {
                tracing::warn!("unwatch {}: {e}", dir.display());
            }
        }
        unwatch
    }

    /// Takes one registered doc off the count of `dir` and leaves the watch.
    /// For a board delete: an unwatch restarts the FSEvents stream, and the
    /// restart loses a change of a doc that is left (#249, #253). The next
    /// `release_watch` that empties the directory drops the watch.
    fn release_count(&self, dir: &Path) {
        self.watcher.lock().expect("watcher lock").uncount(dir);
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
        let watched = match self.acquire_watch(dir) {
            Ok(watched) => watched,
            Err(e) => {
                self.release_watch(dir);
                // A watch that fails has restarted the stream too.
                crate::docs::report_changes(self).await;
                anyhow::bail!("cannot watch {}: {e}", dir.display());
            }
        };
        // Read with no lock held.
        let seen = crate::docs::stamp(path);
        // Upsert before the entry is read so it reflects the post-open state.
        let (entry, is_new) = {
            let mut boards = self.boards.lock().await;
            let reg = boards.registry_mut(board);
            let is_new = crate::docs::upsert_doc(reg, path, via, term_id, seen);
            (reg.entry(path).expect("doc just upserted"), is_new)
        };
        if !is_new {
            self.release_watch(dir);
        }
        self.mark_dirty();
        if watched {
            crate::docs::report_changes(self).await;
        }
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
        if path.parent().is_some_and(|dir| self.release_watch(dir)) {
            crate::docs::report_changes(self).await;
        }
        true
    }

    /// Removes a board and takes its docs off their directories' counts. It
    /// drops no watch (`release_count`). False for the last board or an
    /// unknown id.
    pub async fn delete_board(&self, id: &str) -> bool {
        let deleted = self.boards.lock().await.delete(id);
        let Some(board) = deleted else { return false };
        self.mark_dirty();
        for dir in board.registry.docs.keys().filter_map(|p| p.parent()) {
            self.release_count(dir);
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
    use std::time::{Duration, SystemTime};

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
        assert!(!watched(&daemon, &tmp), "a doc in a subdirectory does not count");

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

    /// Each unwatch restarts the FSEvents stream, and a change of a doc that
    /// is left is lost in the restart (#249, #253). So a delete drops no
    /// watch. It takes the board's docs off the counts, and the next close in
    /// a directory then drops that directory's watch as usual.
    #[tokio::test]
    async fn deleting_a_board_drops_no_watch_and_gives_back_its_counts() {
        let (tmp, shared, daemon) = daemon_with_doc_dir("delete-board");
        let own = tmp.join("own");
        std::fs::create_dir_all(&own).unwrap();
        open_doc(&daemon, None, &shared.join("a.md")).await;
        let other = daemon.boards.lock().await.create();
        open_doc(&daemon, Some(&other), &shared.join("b.md")).await;
        open_doc(&daemon, Some(&other), &own.join("c.md")).await;
        open_doc(&daemon, Some(&other), &own.join("d.md")).await;

        assert!(daemon.delete_board(&other).await);
        assert!(watched(&daemon, &own), "the delete drops no watch");
        assert!(watched(&daemon, &shared));
        assert!(!daemon.delete_board(&other).await, "a second delete finds no board");

        let later = own.join("e.md");
        open_doc(&daemon, None, &later).await;
        assert!(daemon.close_doc(&later).await);
        assert!(!watched(&daemon, &own), "the deleted board's two docs are off the count");

        assert!(daemon.close_doc(&shared.join("a.md")).await);
        assert!(!watched(&daemon, &shared), "and its doc in the shared directory");
        assert!(daemon.watcher.lock().unwrap().doc_counts.is_empty(), "no count is left at zero");

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

    struct Silent;

    impl WakeSource for Silent {
        fn watch(&mut self, _: &Path) -> anyhow::Result<()> {
            Ok(())
        }

        fn unwatch(&mut self, _: &Path) -> anyhow::Result<()> {
            Ok(())
        }
    }

    /// A daemon that its watcher never wakes, and the pushes to its app.
    async fn silent_daemon(tag: &str) -> (PathBuf, Arc<Daemon>, Arc<Notify>, mpsc::Receiver<Msg>) {
        let tmp = tmp_dir(tag);
        let wake = Arc::new(Notify::new());
        let daemon = Daemon::with_source(tmp.join("state.json"), Box::new(Silent), wake.clone());
        let app = connect_app(&daemon).await;
        (tmp, daemon, wake, app)
    }

    async fn connect_app(daemon: &Daemon) -> mpsc::Receiver<Msg> {
        let (tx, rx) = mpsc::channel(16);
        daemon.install_app(tx, None).await;
        rx
    }

    async fn next_file_event(app: &mut mpsc::Receiver<Msg>) -> u64 {
        let msg = tokio::time::timeout(Duration::from_secs(5), app.recv()).await.expect("a push");
        let Some(Msg::FileEvent { mtime_ms, .. }) = msg else { panic!("expected a file_event, got {msg:?}") };
        mtime_ms
    }

    async fn last_changed(daemon: &Daemon, doc: &Path) -> Option<u64> {
        daemon.boards.lock().await.active_registry().docs[doc].last_changed_ms
    }

    fn write_doc(path: PathBuf) -> PathBuf {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "doc").unwrap();
        path
    }

    /// Gives the file an mtime that it did not have, and returns it in ms.
    fn change(path: &Path) -> u64 {
        static MINUTES: AtomicU32 = AtomicU32::new(1);
        let later = SystemTime::now() + Duration::from_secs(60 * u64::from(MINUTES.fetch_add(1, Ordering::Relaxed)));
        std::fs::File::options().write(true).open(path).unwrap().set_modified(later).unwrap();
        crate::boards::epoch_ms(later)
    }

    fn file_events(app: &mut mpsc::Receiver<Msg>) -> Vec<(PathBuf, u64)> {
        let mut events = Vec::new();
        while let Ok(msg) = app.try_recv() {
            if let Msg::FileEvent { path, mtime_ms } = msg {
                events.push((PathBuf::from(path), mtime_ms));
            }
        }
        events
    }

    // #253: an unwatch restarts the FSEvents stream, and the restart loses the
    // events that the stream has not delivered yet. So the close looks at the
    // docs itself; here no wake comes at all.
    #[tokio::test]
    async fn a_close_reports_a_change_that_no_wake_told_of() {
        let (tmp, daemon, _wake, mut app) = silent_daemon("close-reports").await;
        let kept = write_doc(tmp.join("kept/a.md"));
        let gone = write_doc(tmp.join("gone/b.md"));
        open_doc(&daemon, None, &kept).await;
        open_doc(&daemon, None, &gone).await;

        let changed = change(&kept);
        assert!(daemon.close_doc(&gone).await);
        assert_eq!(file_events(&mut app), vec![(kept, changed)]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // The same for a watch: the first doc of a directory.
    #[tokio::test]
    async fn an_open_reports_a_change_that_no_wake_told_of() {
        let (tmp, daemon, _wake, mut app) = silent_daemon("open-reports").await;
        let kept = write_doc(tmp.join("kept/a.md"));
        let new = write_doc(tmp.join("new/b.md"));
        open_doc(&daemon, None, &kept).await;

        let changed = change(&kept);
        open_doc(&daemon, None, &new).await;
        assert_eq!(file_events(&mut app), vec![(kept, changed)], "and nothing for the doc that was opened");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn a_wake_reports_a_change() {
        let (tmp, daemon, wake, mut app) = silent_daemon("wake-reports").await;
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;

        let changed = change(&doc);
        tokio::task::yield_now().await;
        assert_eq!(file_events(&mut app), vec![], "nothing looked at the doc yet");

        wake.notify_one();
        assert_eq!(next_file_event(&mut app).await, changed);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A wake can come from any file of a watched directory, in the middle of a
    // doc's own burst. docs/protocol.md gives a doc one file_event for a burst.
    #[tokio::test]
    async fn a_look_comes_no_sooner_than_the_burst_window_after_the_one_before() {
        let (tmp, daemon, wake, mut app) = silent_daemon("burst").await;
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;

        let first = change(&doc);
        wake.notify_one();
        assert_eq!(next_file_event(&mut app).await, first);
        let told = std::time::Instant::now();

        let second = change(&doc);
        wake.notify_one();
        assert_eq!(next_file_event(&mut app).await, second);
        assert!(told.elapsed() >= crate::watch::BURST, "the second look came after {:?}", told.elapsed());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // What was seen is what an app was told. A look with no app would take the
    // change and tell nobody; the connect then would find nothing.
    #[tokio::test]
    async fn a_look_takes_nothing_while_no_app_is_connected() {
        let tmp = tmp_dir("no-app");
        let daemon = Daemon::with_source(tmp.join("state.json"), Box::new(Silent), Arc::new(Notify::new()));
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;

        let changed = change(&doc);
        crate::docs::report_changes(&daemon).await;
        assert_eq!(last_changed(&daemon, &doc).await, None);

        let mut app = connect_app(&daemon).await;
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc, changed)]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // doc_refresh, S21: it delivers a change that the daemon has not seen.
    #[tokio::test]
    async fn a_refresh_reports_a_change_that_no_wake_told_of() {
        let (tmp, daemon, _wake, mut app) = silent_daemon("refresh-unseen").await;
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;

        let changed = change(&doc);
        assert!(crate::docs::stat_and_push(&daemon, &doc).await);
        assert_eq!(file_events(&mut app), vec![(doc.clone(), changed)]);
        assert_eq!(last_changed(&daemon, &doc).await, Some(changed));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // doc_refresh, S22: it stats the file. A handler that answers from the
    // recorded `last_changed_ms`, and stats only when there is none, passes
    // every test whose record is empty or agrees with the file. Here the record
    // is there and is old.
    #[tokio::test]
    async fn a_refresh_stats_the_file_and_does_not_replay_what_is_recorded() {
        let (tmp, daemon, wake, mut app) = silent_daemon("refresh-restats").await;
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;
        let first = change(&doc);
        assert!(crate::docs::stat_and_push(&daemon, &doc).await);
        assert_eq!(file_events(&mut app), vec![(doc.clone(), first)]);

        let second = change(&doc);
        assert_ne!(second, first);
        assert!(crate::docs::stat_and_push(&daemon, &doc).await);
        assert_eq!(file_events(&mut app), vec![(doc.clone(), second)], "what the file says now");
        assert_eq!(last_changed(&daemon, &doc).await, Some(second), "recorded, not only announced");

        // The refresh took the file as seen: a look after it has nothing to tell.
        wake.notify_one();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(file_events(&mut app), vec![]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    struct RefusesDir(PathBuf);

    impl WakeSource for RefusesDir {
        fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
            anyhow::ensure!(dir != self.0, "refused");
            Ok(())
        }

        fn unwatch(&mut self, _: &Path) -> anyhow::Result<()> {
            Ok(())
        }
    }

    // notify restarts its stream also for a watch that fails.
    #[tokio::test]
    async fn an_open_that_cannot_watch_reports_a_change_too() {
        let tmp = tmp_dir("refused-reports");
        let refused = tmp.join("refused");
        let daemon =
            Daemon::with_source(tmp.join("state.json"), Box::new(RefusesDir(refused.clone())), Arc::new(Notify::new()));
        let mut app = connect_app(&daemon).await;
        let kept = write_doc(tmp.join("kept/a.md"));
        open_doc(&daemon, None, &kept).await;

        let changed = change(&kept);
        assert!(daemon.open_doc(None, &write_doc(refused.join("b.md")), "t", None).await.is_err());
        assert_eq!(file_events(&mut app), vec![(kept, changed)]);

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
