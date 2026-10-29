use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use tarmac_protocol::{DocEntry, Msg};
use tokio::sync::{Mutex, Notify, mpsc};
use tokio_util::sync::CancellationToken;

use crate::boards::{BoardId, Boards, FileStamp};
use crate::docs::RepoInfo;
use crate::reader::{PathFs, PathGate, RealFs};
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
    /// a count and no watch.
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
    /// One `look` at a time. Taken before `boards`, never while `boards` is
    /// held.
    looking: Mutex<()>,
    gate: PathGate,
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
    fn with_source(state_path: PathBuf, source: Box<dyn WakeSource>, wake: Arc<Notify>) -> Arc<Self> {
        Self::with_fs(state_path, source, wake, Arc::new(RealFs), crate::reader::READ_LIMIT)
    }

    /// `with_source`, whose gate makes its calls on `fs` and waits `limit`
    /// for each.
    fn with_fs(
        state_path: PathBuf,
        source: Box<dyn WakeSource>,
        wake: Arc<Notify>,
        fs: Arc<dyn PathFs>,
        limit: std::time::Duration,
    ) -> Arc<Self> {
        let gate = PathGate::new(fs, limit, {
            let wake = wake.clone();
            Arc::new(move || wake.notify_one())
        });
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
            gate,
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

    pub fn gate(&self) -> &PathGate {
        &self.gate
    }

    pub async fn woken(&self) {
        self.wake.notified().await;
    }

    /// One look: reads the files of `paths` with no `boards` lock held, then
    /// gives the reading to `apply` under that lock. It is the one place that
    /// reads a doc's file for a change, and it runs one at a time, so that an
    /// older reading is never applied after a newer one. Nothing is pushed
    /// from inside it. A doc whose file could not be read in time
    /// (`PathGate`) is not in the reading.
    pub async fn look<P, T>(
        &self,
        paths: impl FnOnce(&Boards) -> P,
        apply: impl FnOnce(&mut Boards, &HashMap<PathBuf, Option<FileStamp>>) -> T,
    ) -> T
    where
        P: IntoIterator<Item = PathBuf>,
    {
        let _one_at_a_time = self.looking.lock().await;
        let paths = paths(&*self.boards.lock().await);
        let now = self.gate.stamps(paths).await;
        apply(&mut *self.boards.lock().await, &now)
    }

    /// Counts one more registered doc in `dir` and watches the directory if it
    /// is not watched yet. The count stands when the watch fails, so each call
    /// is paired with one `release_watch`.
    ///
    /// True when it watched: the stream restarted (`NotifySource`), and the
    /// caller looks at the docs itself (`docs::report_changes`).
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

    /// Registers a doc on `board` (the active one for `None`), or refreshes the
    /// one already there. `seen` and `repo` are the doc's file and repo, read
    /// by the caller, for a doc that is new to `board`. Fails, with nothing
    /// registered, when its directory cannot be watched.
    pub async fn open_doc(
        &self,
        board: Option<&str>,
        path: &Path,
        via: &str,
        term_id: Option<String>,
        seen: Option<FileStamp>,
        repo: Option<RepoInfo>,
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
        // Upsert before the entry is read so it reflects the post-open state.
        let (entry, is_new) = {
            let mut boards = self.boards.lock().await;
            let reg = boards.registry_mut(board);
            let is_new = crate::docs::upsert_doc(reg, path, via, term_id, seen, repo);
            (reg.entry(path).expect("doc just upserted"), is_new)
        };
        if !is_new {
            self.release_watch(dir);
        }
        self.mark_dirty();
        if watched {
            crate::docs::report_changes(self).await;
        } else {
            // `seen` was read before the doc was registered, and the wake of
            // a change in between could come before it too.
            self.wake.notify_one();
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

    /// Removes a board and takes its docs off their directories' counts,
    /// dropping the watch of each directory that is left empty. False for the
    /// last board or an unknown id. It does not look at the docs: its caller
    /// sends the active board next, and that send looks
    /// (`conn::change_and_send_active_board`).
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

    /// Pushes to the connected app. False when there is none, or it went
    /// away: the frame is dropped.
    pub async fn push(&self, msg: Msg) -> bool {
        let tx = self.app.lock().await.as_ref().map(|s| s.tx.clone());
        match tx {
            Some(tx) => tx.send(msg).await.is_ok(),
            None => false,
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
        daemon.open_doc(board, doc, "t", None, crate::reader::stamp(doc), None).await.unwrap();
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

    #[tokio::test]
    async fn deleting_a_board_unwatches_the_dirs_no_board_is_left_in() {
        let (tmp, shared, daemon) = daemon_with_doc_dir("delete-board");
        let own = tmp.join("own");
        std::fs::create_dir_all(&own).unwrap();
        open_doc(&daemon, None, &shared.join("a.md")).await;
        let other = daemon.boards.lock().await.create();
        open_doc(&daemon, Some(&other), &shared.join("b.md")).await;
        open_doc(&daemon, Some(&other), &own.join("c.md")).await;
        open_doc(&daemon, Some(&other), &own.join("d.md")).await;

        assert!(daemon.delete_board(&other).await);
        assert!(!watched(&daemon, &own), "no board is left with a doc there");
        assert!(watched(&daemon, &shared), "board-0 still has a doc there");
        assert!(!daemon.delete_board(&other).await, "a second delete finds no board");

        assert!(daemon.close_doc(&shared.join("a.md")).await);
        assert!(!watched(&daemon, &shared));
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

        assert!(daemon.open_doc(None, &doc, "t", None, None, None).await.is_err(), "the directory does not exist");
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

    /// A daemon that its watcher never wakes, with no app.
    fn silent(tag: &str) -> (PathBuf, Arc<Daemon>) {
        let tmp = tmp_dir(tag);
        let daemon =
            Daemon::with_source(tmp.join("state.json"), Box::new(Silent), Arc::new(Notify::new()));
        (tmp, daemon)
    }

    /// `silent`, and the pushes to its app.
    async fn silent_daemon(tag: &str) -> (PathBuf, Arc<Daemon>, mpsc::Receiver<Msg>) {
        let (tmp, daemon) = silent(tag);
        let app = connect_app(&daemon).await;
        (tmp, daemon, app)
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

    /// Waits until the state file has the doc with `want` as its
    /// `last_changed_ms`. A test waits for the save of the open (`None`)
    /// first: a save comes 150 ms after it was asked for, so the one that the
    /// open asked for would carry a later record too.
    async fn wait_for_saved(tmp: &Path, doc: &Path, want: Option<u64>) {
        let saved = || {
            let boards = crate::persist::load(&tmp.join("state.json"));
            boards.active_registry().docs.get(doc).map(|info| info.last_changed_ms)
        };
        for _ in 0..200 {
            if saved() == Some(want) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("the state file never had {want:?}, it has {:?}", saved());
    }

    fn write_doc(path: PathBuf) -> PathBuf {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "doc").unwrap();
        path
    }

    fn mtime(path: &Path) -> SystemTime {
        crate::reader::stamp(path).unwrap().mtime
    }

    fn set_mtime(path: &Path, mtime: SystemTime) {
        std::fs::File::options().write(true).open(path).unwrap().set_modified(mtime).unwrap();
    }

    /// Gives the file an mtime that it did not have, and returns it in ms.
    fn change(path: &Path) -> u64 {
        static MINUTES: AtomicU32 = AtomicU32::new(1);
        let later = SystemTime::now() + Duration::from_secs(60 * u64::from(MINUTES.fetch_add(1, Ordering::Relaxed)));
        set_mtime(path, later);
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
        let (tmp, daemon, mut app) = silent_daemon("close-reports").await;
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
        let (tmp, daemon, mut app) = silent_daemon("open-reports").await;
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
        let (tmp, daemon, mut app) = silent_daemon("wake-reports").await;
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;

        let changed = change(&doc);
        tokio::task::yield_now().await;
        assert_eq!(file_events(&mut app), vec![], "nothing looked at the doc yet");

        daemon.wake.notify_one();
        assert_eq!(next_file_event(&mut app).await, changed);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A wake can come from any file of a watched directory, in the middle of a
    // doc's own burst. docs/protocol.md gives a doc one file_event for a burst.
    #[tokio::test]
    async fn a_look_comes_no_sooner_than_the_burst_window_after_the_one_before() {
        let (tmp, daemon, mut app) = silent_daemon("burst").await;
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;

        // Taken before the first look: the wait starts when that look ends.
        let before = std::time::Instant::now();
        let first = change(&doc);
        daemon.wake.notify_one();
        assert_eq!(next_file_event(&mut app).await, first);

        let second = change(&doc);
        daemon.wake.notify_one();
        assert_eq!(next_file_event(&mut app).await, second);
        assert!(before.elapsed() >= crate::watch::BURST, "the second look came after {:?}", before.elapsed());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A look with no app records the change, so a restart keeps its time, and
    // holds it for the look that has an app to tell.
    #[tokio::test]
    async fn a_look_with_no_app_records_the_change_and_holds_it_to_be_told() {
        let (tmp, daemon) = silent("no-app");
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;
        wait_for_saved(&tmp, &doc, None).await;

        let changed = change(&doc);
        crate::docs::report_changes(&daemon).await;
        assert_eq!(last_changed(&daemon, &doc).await, Some(changed));
        wait_for_saved(&tmp, &doc, Some(changed)).await;

        let mut app = connect_app(&daemon).await;
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc.clone(), changed)]);
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![], "it is told one time");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A save writes the state file. With a doc in that directory, a look that
    // asked for a save each time would wake itself for ever.
    #[tokio::test]
    async fn a_look_that_records_nothing_asks_for_no_save() {
        let (tmp, daemon) = silent("no-save");
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;
        wait_for_saved(&tmp, &doc, None).await;

        let changed = change(&doc);
        crate::docs::report_changes(&daemon).await;
        wait_for_saved(&tmp, &doc, Some(changed)).await;
        let saved_at = mtime(&tmp.join("state.json"));

        // The change is held, since there is no app, and is tried at each look.
        crate::docs::report_changes(&daemon).await;
        crate::docs::report_changes(&daemon).await;
        tokio::time::sleep(Duration::from_millis(400)).await;
        assert_eq!(mtime(&tmp.join("state.json")), saved_at);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // The record follows the file also while nobody is told: a file that is
    // changed and put back is recorded as it is.
    #[tokio::test]
    async fn a_change_that_went_back_with_no_app_is_recorded_as_the_file_is() {
        let (tmp, daemon) = silent("no-app-back");
        let doc = write_doc(tmp.join("d/a.md"));
        let first = mtime(&doc);
        open_doc(&daemon, None, &doc).await;

        let changed = change(&doc);
        crate::docs::report_changes(&daemon).await;
        assert_eq!(last_changed(&daemon, &doc).await, Some(changed));

        set_mtime(&doc, first);
        crate::docs::report_changes(&daemon).await;
        assert_eq!(last_changed(&daemon, &doc).await, Some(crate::boards::epoch_ms(first)));

        let mut app = connect_app(&daemon).await;
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc, crate::boards::epoch_ms(first))]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // An app that goes away between the look and the push: its frame is
    // dropped, and the change is held for the next app.
    #[tokio::test]
    async fn a_change_whose_app_went_away_is_told_to_the_next_app() {
        let (tmp, daemon, app) = silent_daemon("app-gone").await;
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;

        drop(app);
        let changed = change(&doc);
        crate::docs::report_changes(&daemon).await;

        let mut app = connect_app(&daemon).await;
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc, changed)]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // The hold is for the board whose look took the change. The active board
    // can be another one by the time the push fails.
    #[tokio::test]
    async fn a_change_is_held_for_its_board_when_another_board_is_active() {
        let (tmp, daemon) = silent("held-board");
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;
        let changed = change(&doc);
        daemon.look(|_| vec![doc.clone()], |boards, now| boards.active_registry_mut().take_changes(now)).await;

        let other = daemon.boards.lock().await.create();
        open_doc(&daemon, Some(&other), &doc).await;
        crate::docs::push_file_event(&daemon, crate::boards::DEFAULT_BOARD_ID, &doc, changed).await;

        let mut app = connect_app(&daemon).await;
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![], "the board that is active was not the one");
        daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc, changed)]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A refresh with no app is held like a look's change, and a refresh tells
    // what was held: the look after it has nothing left.
    #[tokio::test]
    async fn a_refresh_holds_what_reached_no_app_and_tells_what_was_held() {
        let (tmp, daemon) = silent("refresh-held");
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;

        let changed = change(&doc);
        assert!(crate::docs::stat_and_push(&daemon, &doc).await);
        let mut app = connect_app(&daemon).await;
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc.clone(), changed)], "the refresh was held");

        drop(app);
        let again = change(&doc);
        crate::docs::report_changes(&daemon).await;
        let mut app = connect_app(&daemon).await;
        assert!(crate::docs::stat_and_push(&daemon, &doc).await);
        assert_eq!(file_events(&mut app), vec![(doc.clone(), again)]);
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![], "the refresh told it");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A save that replaces the file by one with the same mtime and length.
    #[tokio::test]
    async fn a_file_that_is_replaced_with_the_same_mtime_and_length_is_a_change() {
        let (tmp, daemon, mut app) = silent_daemon("replaced").await;
        let doc = write_doc(tmp.join("d/a.md"));
        let kept = mtime(&doc);
        open_doc(&daemon, None, &doc).await;

        let new = tmp.join("d/a.md.new");
        std::fs::write(&new, "cod").unwrap();
        set_mtime(&new, kept);
        std::fs::rename(&new, &doc).unwrap();
        crate::docs::report_changes(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc, crate::boards::epoch_ms(kept))]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // `Daemon::look` reads the files with no `boards` lock held. If two looks
    // ran at once, one that read a doc before its change would apply that
    // reading after the other recorded the change. Each round starts a look
    // at every doc, waits a part of the time that its reads take, then
    // changes one doc and records the change with a second look. The doc goes
    // round because its place in the read order is fixed for a process.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_older_reading_is_never_taken_after_a_newer_one() {
        let (tmp, daemon, mut app) = silent_daemon("one-look").await;
        // Its pushes are not what is under test, and a push waits when 16 are unread.
        tokio::spawn(async move { while app.recv().await.is_some() {} });
        let docs: Vec<PathBuf> = (0..200).map(|i| write_doc(tmp.join(format!("d/{i}.md")))).collect();
        for doc in &docs {
            open_doc(&daemon, None, doc).await;
        }

        for round in 0..400 {
            let doc = &docs[round % docs.len()];
            let look = tokio::spawn({
                let daemon = daemon.clone();
                async move { crate::docs::report_changes(&daemon).await }
            });
            let into_the_reads = std::time::Instant::now() + Duration::from_micros(round as u64 % 40 * 10);
            while std::time::Instant::now() < into_the_reads {
                std::hint::spin_loop();
            }
            let changed = change(doc);
            assert!(crate::docs::stat_and_push(&daemon, doc).await);
            look.await.unwrap();
            assert_eq!(last_changed(&daemon, doc).await, Some(changed), "round {round}");
        }

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // doc_refresh, S21: it delivers a change that the daemon has not seen.
    #[tokio::test]
    async fn a_refresh_reports_a_change_that_no_wake_told_of() {
        let (tmp, daemon, mut app) = silent_daemon("refresh-unseen").await;
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
        let (tmp, daemon, mut app) = silent_daemon("refresh-restats").await;
        let doc = write_doc(tmp.join("d/a.md"));
        open_doc(&daemon, None, &doc).await;
        wait_for_saved(&tmp, &doc, None).await;
        let first = change(&doc);
        assert!(crate::docs::stat_and_push(&daemon, &doc).await);
        assert_eq!(file_events(&mut app), vec![(doc.clone(), first)]);
        wait_for_saved(&tmp, &doc, Some(first)).await;

        let second = change(&doc);
        assert_ne!(second, first);
        assert!(crate::docs::stat_and_push(&daemon, &doc).await);
        assert_eq!(file_events(&mut app), vec![(doc.clone(), second)], "what the file says now");
        assert_eq!(last_changed(&daemon, &doc).await, Some(second), "recorded, not only announced");
        wait_for_saved(&tmp, &doc, Some(second)).await;

        // The refresh took the file as seen: a look after it has nothing to tell.
        daemon.wake.notify_one();
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
        assert!(daemon.open_doc(None, &write_doc(refused.join("b.md")), "t", None, None, None).await.is_err());
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

    const LIMIT: Duration = Duration::from_millis(200);

    #[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
    enum Call {
        Resolve,
        Stamp,
        RepoOf,
    }

    /// `RealFs`, whose calls that the test holds do not return until the
    /// sender of `until_released` is dropped: a volume that is gone. It counts
    /// every call of each method, and those it held.
    struct StuckFs {
        holds: std::sync::Mutex<Vec<(Call, PathBuf)>>,
        until_released: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
        calls: std::sync::Mutex<HashMap<Call, u32>>,
        held: std::sync::Mutex<HashMap<Call, u32>>,
    }

    impl StuckFs {
        /// Holds each later `call` on a path under `under`.
        fn hold(&self, call: Call, under: &Path) {
            self.holds.lock().unwrap().push((call, under.to_owned()));
        }

        fn wait_if_held(&self, call: Call, path: &Path) {
            *self.calls.lock().unwrap().entry(call).or_default() += 1;
            let held = self.holds.lock().unwrap().iter().any(|(c, under)| *c == call && path.starts_with(under));
            if held {
                *self.held.lock().unwrap().entry(call).or_default() += 1;
                let _ = self.until_released.lock().unwrap().recv();
            }
        }

        fn calls(&self, call: Call) -> u32 {
            self.calls.lock().unwrap().get(&call).copied().unwrap_or(0)
        }

        fn held(&self, call: Call) -> u32 {
            self.held.lock().unwrap().get(&call).copied().unwrap_or(0)
        }
    }

    impl PathFs for StuckFs {
        fn resolve(&self, raw: &Path) -> Result<(PathBuf, FileStamp), String> {
            self.wait_if_held(Call::Resolve, raw);
            RealFs.resolve(raw)
        }

        fn stamp(&self, path: &Path) -> Option<FileStamp> {
            self.wait_if_held(Call::Stamp, path);
            RealFs.stamp(path)
        }

        fn repo_of(&self, doc: &Path) -> Option<crate::docs::RepoInfo> {
            self.wait_if_held(Call::RepoOf, doc);
            RealFs.repo_of(doc)
        }
    }

    /// The test holds the sender to its end, a panic included: a runtime
    /// waits for its blocking threads when it is dropped.
    fn stuck_fs() -> (Arc<StuckFs>, std::sync::mpsc::Sender<()>) {
        let (release, until_released) = std::sync::mpsc::channel();
        let fs = Arc::new(StuckFs {
            holds: std::sync::Mutex::default(),
            until_released: std::sync::Mutex::new(until_released),
            calls: std::sync::Mutex::default(),
            held: std::sync::Mutex::default(),
        });
        (fs, release)
    }

    fn stuck_reader() -> (PathGate, Arc<StuckFs>, std::sync::mpsc::Sender<()>) {
        let (fs, release) = stuck_fs();
        (PathGate::new(fs.clone(), LIMIT, Arc::new(|| {})), fs, release)
    }

    /// A daemon that its watcher never wakes, whose gate calls `fs`, with no
    /// app.
    fn gated(tmp: &Path, fs: Arc<StuckFs>) -> Arc<Daemon> {
        Daemon::with_fs(tmp.join("state.json"), Box::new(Silent), Arc::new(Notify::new()), fs, LIMIT)
    }

    /// `silent_daemon` with `gone/a.md` open on the active board, whose reads
    /// get stuck once the test says so.
    async fn stuck_daemon(
        tag: &str,
    ) -> (PathBuf, Arc<Daemon>, mpsc::Receiver<Msg>, Arc<StuckFs>, std::sync::mpsc::Sender<()>) {
        let tmp = tmp_dir(tag);
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, release) = stuck_fs();
        let daemon = gated(&tmp, fs.clone());
        let app = connect_app(&daemon).await;
        open_doc(&daemon, None, &doc).await;
        (tmp, daemon, app, fs, release)
    }

    /// Runs `look` on a task of its own: a read that blocks the test's task
    /// would block the timer that ends the wait too.
    async fn answers<T: Send + 'static>(look: impl Future<Output = T> + Send + 'static) -> T {
        tokio::time::timeout(Duration::from_secs(2), tokio::spawn(look)).await.expect("an answer").unwrap()
    }

    async fn look_at(daemon: &Arc<Daemon>) {
        let daemon = daemon.clone();
        answers(async move { crate::docs::report_changes(&daemon).await }).await;
    }

    // #259
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_read_that_does_not_return_costs_only_its_own_doc() {
        let (tmp, daemon, mut app, stuck, _release) = stuck_daemon("stuck-wake").await;
        let doc = write_doc(tmp.join("d/b.md"));
        open_doc(&daemon, None, &doc).await;

        stuck.hold(Call::Stamp, &tmp.join("gone"));
        let changed = change(&doc);
        look_at(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc, changed)]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // In a look, the order of the docs is the order of a hash map: here the
    // stuck reads come first.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_reads_after_one_that_does_not_return_go_on() {
        let tmp = tmp_dir("stuck-first");
        let doc = write_doc(tmp.join("d/b.md"));
        let (reader, stuck, _release) = stuck_reader();
        stuck.hold(Call::Stamp, &tmp.join("gone"));

        let paths = vec![write_doc(tmp.join("gone/a.md")), write_doc(tmp.join("gone/b.md")), doc.clone()];
        let now = answers(async move { reader.stamps(paths).await }).await;
        assert_eq!(now, HashMap::from([(doc.clone(), crate::reader::stamp(&doc))]));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A volume that is gone takes each of its docs.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_look_waits_two_limits_at_most_for_all_its_stuck_reads() {
        let tmp = tmp_dir("stuck-many");
        let docs: Vec<PathBuf> = (0..4).map(|i| write_doc(tmp.join(format!("gone/{i}.md")))).collect();
        let (reader, stuck, _release) = stuck_reader();
        stuck.hold(Call::Stamp, &tmp.join("gone"));

        let before = std::time::Instant::now();
        let now = answers(async move { reader.stamps(docs).await }).await;
        assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
        assert_eq!(now, HashMap::new());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // The second stuck read is on a thread of its own (`read_apart`), and the
    // next look must not start it again either.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn no_stuck_read_of_a_look_is_read_again_by_the_next() {
        let tmp = tmp_dir("stuck-apart");
        let docs: Vec<PathBuf> = (0..2).map(|i| write_doc(tmp.join(format!("gone/{i}.md")))).collect();
        let (reader, stuck, _release) = stuck_reader();
        let reader = Arc::new(reader);
        stuck.hold(Call::Stamp, &tmp.join("gone"));

        for _ in 0..2 {
            let (reader, docs) = (reader.clone(), docs.clone());
            answers(async move { reader.stamps(docs).await }).await;
        }
        assert_eq!(stuck.held(Call::Stamp), 2);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // A switch looks at the docs of every board, the board it shows among them.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_switch_answers_while_a_read_does_not_return() {
        let (tmp, daemon, _app, stuck, _release) = stuck_daemon("stuck-switch").await;
        let other = daemon.boards.lock().await.create();
        let doc = write_doc(tmp.join("d/b.md"));
        open_doc(&daemon, Some(&other), &doc).await;
        daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);

        stuck.hold(Call::Stamp, &tmp.join("gone"));
        let changed = change(&doc);
        let switch = {
            let daemon = daemon.clone();
            async move {
                daemon
                    .look(Boards::doc_paths, |boards, now| {
                        boards.set_active(&other);
                        crate::docs::take_to_tell(&daemon, boards.active_registry_mut(), now)
                    })
                    .await
            }
        };
        assert_eq!(answers(switch).await, vec![(doc, changed)]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // Each look would otherwise leave one more thread stuck on the same file.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_doc_whose_read_is_out_is_read_again_only_when_it_returned() {
        let (tmp, daemon, mut app, stuck, release) = stuck_daemon("stuck-again").await;
        let doc = write_doc(tmp.join("d/b.md"));
        open_doc(&daemon, None, &doc).await;
        stuck.hold(Call::Stamp, &tmp.join("gone"));
        look_at(&daemon).await;
        assert_eq!(stuck.held(Call::Stamp), 1);

        let changed = change(&doc);
        let before = std::time::Instant::now();
        look_at(&daemon).await;
        assert!(before.elapsed() < LIMIT, "it waited {:?} for a read that is out", before.elapsed());
        assert_eq!(stuck.held(Call::Stamp), 1);
        assert_eq!(file_events(&mut app), vec![(doc, changed)]);

        drop(release);
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while stuck.held(Call::Stamp) < 2 {
            assert!(std::time::Instant::now() < deadline, "the doc is never read again");
            tokio::time::sleep(Duration::from_millis(10)).await;
            look_at(&daemon).await;
        }

        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// An open registers the canonical path, and a hold on a resolve matches
    /// the path as given: here they are one (/var -> /private/var).
    fn canon_tmp(tag: &str) -> PathBuf {
        std::fs::canonicalize(tmp_dir(tag)).unwrap()
    }

    async fn try_open(daemon: &Arc<Daemon>, doc: &Path) -> Result<(), String> {
        let (daemon, doc) = (daemon.clone(), doc.to_str().unwrap().to_owned());
        answers(async move { crate::docs::handle_open(&daemon, &doc, "cli", None, None).await }).await
    }

    fn did_not_answer(daemon: &Daemon, doc: &Path) -> Result<(), String> {
        let answer = daemon.gate().did_not_answer(&format!("cannot open {}", doc.display()));
        assert!(answer.starts_with(&format!("cannot open {}: did not answer in ", doc.display())));
        Err(answer)
    }

    async fn registered(daemon: &Daemon, doc: &Path) -> bool {
        daemon.boards.lock().await.doc_paths().contains(doc)
    }

    fn docs_opened(app: &mut mpsc::Receiver<Msg>) -> Vec<PathBuf> {
        let mut opened = Vec::new();
        while let Ok(msg) = app.try_recv() {
            if let Msg::DocOpened(entry) = msg {
                opened.push(PathBuf::from(entry.path));
            }
        }
        opened
    }

    async fn eventually(what: &str, done: impl Fn() -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while !done() {
            assert!(std::time::Instant::now() < deadline, "{what} never happened");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// The reading of one look at `doc`.
    async fn look_at_doc(daemon: &Arc<Daemon>, doc: &Path) -> HashMap<PathBuf, Option<FileStamp>> {
        let (daemon, doc) = (daemon.clone(), doc.to_owned());
        answers(async move { daemon.look(|_| vec![doc], |_, now| now.clone()).await }).await
    }

    // 2610.0012 S1
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_open_whose_path_does_not_answer_fails_in_its_limit() {
        let tmp = canon_tmp("open-stuck");
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, _release) = stuck_fs();
        fs.hold(Call::Resolve, &tmp.join("gone"));
        let daemon = gated(&tmp, fs.clone());

        let before = std::time::Instant::now();
        assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
        assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
        assert!(!registered(&daemon, &doc).await);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S2
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_second_open_of_a_path_that_is_out_fails_at_once_with_no_call() {
        let tmp = canon_tmp("open-stuck-again");
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, _release) = stuck_fs();
        fs.hold(Call::Resolve, &tmp.join("gone"));
        let daemon = gated(&tmp, fs.clone());
        assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));

        let before = std::time::Instant::now();
        assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
        assert!(before.elapsed() < LIMIT, "it waited {:?} for a call that is out", before.elapsed());
        assert_eq!(fs.calls(Call::Resolve), 1);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S3
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_open_answers_while_another_open_waits_for_its_path() {
        let tmp = canon_tmp("open-beside-stuck");
        let stuck = write_doc(tmp.join("gone/a.md"));
        let doc = write_doc(tmp.join("d/b.md"));
        let (fs, _release) = stuck_fs();
        fs.hold(Call::Resolve, &tmp.join("gone"));
        let daemon = gated(&tmp, fs.clone());
        let mut app = connect_app(&daemon).await;

        let stuck_open = tokio::spawn({
            let (daemon, stuck) = (daemon.clone(), stuck.to_str().unwrap().to_owned());
            async move { crate::docs::handle_open(&daemon, &stuck, "cli", None, None).await }
        });
        eventually("the held resolve", || fs.held(Call::Resolve) == 1).await;
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert_eq!(docs_opened(&mut app), vec![doc]);
        assert_eq!(stuck_open.await.unwrap(), did_not_answer(&daemon, &stuck));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S4: the caller has had its error, and runs the open again.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_open_that_did_not_answer_is_not_finished_when_its_call_returns() {
        let tmp = canon_tmp("open-not-late");
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, release) = stuck_fs();
        fs.hold(Call::Resolve, &tmp.join("gone"));
        let daemon = gated(&tmp, fs.clone());
        let mut app = connect_app(&daemon).await;
        assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));

        drop(release);
        eventually("the return of the resolve", || !daemon.gate().is_out_dir(&tmp.join("gone"))).await;
        assert!(!registered(&daemon, &doc).await);
        assert_eq!(docs_opened(&mut app), Vec::<PathBuf>::new());

        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert_eq!(fs.calls(Call::Resolve), 2);
        assert!(registered(&daemon, &doc).await);
        assert_eq!(docs_opened(&mut app), vec![doc]);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S7
    #[tokio::test]
    async fn an_open_answers_a_missing_path_a_directory_and_a_file_as_before() {
        let tmp = canon_tmp("open-texts");
        let daemon = Daemon::with_source(tmp.join("state.json"), Box::new(Silent), Arc::new(Notify::new()));
        let missing = tmp.join("missing.md");
        let dir = tmp.join("dir");
        std::fs::create_dir_all(&dir).unwrap();
        let doc = write_doc(tmp.join("d/a.md"));

        assert_eq!(
            try_open(&daemon, &missing).await,
            Err(format!("cannot open {}: No such file or directory (os error 2)", missing.display()))
        );
        assert_eq!(try_open(&daemon, &dir).await, Err(format!("not a regular file: {}", dir.display())));
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert!(registered(&daemon, &doc).await);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S8: an open and a look of one path share the call that is
    // out, the open first.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_look_does_not_read_a_path_whose_open_is_out() {
        let tmp = canon_tmp("open-then-look");
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, _release) = stuck_fs();
        let daemon = gated(&tmp, fs.clone());
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        fs.hold(Call::Resolve, &tmp.join("gone"));
        fs.hold(Call::Stamp, &tmp.join("gone"));

        assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
        let before = std::time::Instant::now();
        assert_eq!(look_at_doc(&daemon, &doc).await, HashMap::new());
        assert!(before.elapsed() < LIMIT, "it waited {:?} for a call that is out", before.elapsed());
        assert_eq!(fs.held(Call::Resolve) + fs.held(Call::Stamp), 1);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S8: the look first.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_open_does_not_resolve_a_path_whose_look_is_out() {
        let tmp = canon_tmp("look-then-open");
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, _release) = stuck_fs();
        let daemon = gated(&tmp, fs.clone());
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        fs.hold(Call::Resolve, &tmp.join("gone"));
        fs.hold(Call::Stamp, &tmp.join("gone"));
        assert_eq!(look_at_doc(&daemon, &doc).await, HashMap::new());
        let resolves = fs.calls(Call::Resolve);

        let before = std::time::Instant::now();
        assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
        assert!(before.elapsed() < LIMIT, "it waited {:?} for a call that is out", before.elapsed());
        assert_eq!(fs.calls(Call::Resolve), resolves);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    async fn repo_of(daemon: &Daemon, doc: &Path) -> (Option<String>, Option<String>, Option<u8>) {
        let entry = daemon.boards.lock().await.active_registry().entry(doc).unwrap();
        (entry.repo, entry.repo_root, entry.repo_color)
    }

    /// A temp dir in a repo, with a doc whose open had its dir watched.
    async fn in_a_repo(tag: &str) -> (PathBuf, PathBuf, Arc<Daemon>, Arc<StuckFs>, std::sync::mpsc::Sender<()>) {
        let tmp = canon_tmp(tag);
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        let open = write_doc(tmp.join("d/a.md"));
        let (fs, release) = stuck_fs();
        let daemon = gated(&tmp, fs.clone());
        assert_eq!(try_open(&daemon, &open).await, Ok(()));
        assert!(repo_of(&daemon, &open).await.0.is_some(), "the doc is in a repo");
        (tmp, open, daemon, fs, release)
    }

    // 2610.0012 S5
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_new_doc_whose_repo_does_not_answer_opens_with_no_repo() {
        let (tmp, _, daemon, fs, _release) = in_a_repo("walk-stuck").await;
        let doc = write_doc(tmp.join("d/b.md"));
        fs.hold(Call::RepoOf, &doc);

        let before = std::time::Instant::now();
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
        assert_eq!(repo_of(&daemon, &doc).await, (None, None, None));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S6: the next startup fills a missing repo in, not a re-open.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_reopen_does_not_look_for_the_repo_again() {
        let (tmp, open, daemon, fs, release) = in_a_repo("walk-once").await;
        let repo = repo_of(&daemon, &open).await;
        let walks = fs.calls(Call::RepoOf);
        assert_eq!(try_open(&daemon, &open).await, Ok(()));
        assert_eq!(fs.calls(Call::RepoOf), walks);
        assert_eq!(repo_of(&daemon, &open).await, repo);

        let doc = write_doc(tmp.join("d/b.md"));
        fs.hold(Call::RepoOf, &doc);
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        drop(release);
        eventually("the return of the walk", || !daemon.gate().is_out_dir(&tmp.join("d"))).await;
        let walks = fs.calls(Call::RepoOf);
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert_eq!(fs.calls(Call::RepoOf), walks);
        assert_eq!(repo_of(&daemon, &doc).await, (None, None, None));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S8b: `returned` wakes the daemon, and the look reads what no
    // wake told of.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_read_that_returns_after_its_limit_wakes_a_look() {
        let (tmp, daemon, mut app, stuck, release) = stuck_daemon("returned-wakes").await;
        let doc = write_doc(tmp.join("d/b.md"));
        open_doc(&daemon, None, &doc).await;
        stuck.hold(Call::Stamp, &tmp.join("gone"));
        look_at(&daemon).await;
        assert_eq!(stuck.held(Call::Stamp), 1);

        let changed = change(&doc);
        drop(release);
        assert_eq!(next_file_event(&mut app).await, changed);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // An open's call, and a look's on each of its two steps.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn each_call_that_returns_after_its_limit_calls_returned() {
        let tmp = tmp_dir("returned-each");
        let docs: Vec<PathBuf> = (0..3).map(|i| write_doc(tmp.join(format!("gone/{i}.md")))).collect();
        let (fs, release) = stuck_fs();
        fs.hold(Call::Resolve, &tmp.join("gone"));
        fs.hold(Call::Stamp, &tmp.join("gone"));
        let returned = Arc::new(AtomicU32::new(0));
        let gate = Arc::new(PathGate::new(fs, LIMIT, {
            let returned = returned.clone();
            Arc::new(move || {
                returned.fetch_add(1, Ordering::SeqCst);
            })
        }));

        let (resolving, key) = (gate.clone(), docs[0].clone());
        let resolved = answers(async move {
            let raw = key.clone();
            resolving.run(&key, move |fs| fs.resolve(&raw)).await
        });
        assert!(resolved.await.is_err());
        let (reading, paths) = (gate.clone(), docs[1..].to_vec());
        assert_eq!(answers(async move { reading.stamps(paths).await }).await, HashMap::new());
        assert_eq!(returned.load(Ordering::SeqCst), 0);

        drop(release);
        eventually("three returns", || returned.load(Ordering::SeqCst) == 3).await;
        assert!(!gate.is_out_dir(&tmp.join("gone")));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    fn spawn_open(daemon: &Arc<Daemon>, doc: &Path) -> tokio::task::JoinHandle<Result<(), String>> {
        let (daemon, doc) = (daemon.clone(), doc.to_str().unwrap().to_owned());
        tokio::spawn(async move { crate::docs::handle_open(&daemon, &doc, "cli", None, None).await })
    }

    // One call on a key at a time: a second caller does not start a thread
    // of its own on a path that does not answer.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn two_opens_of_a_path_that_does_not_answer_make_one_call() {
        let tmp = canon_tmp("open-twice-at-once");
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, _release) = stuck_fs();
        fs.hold(Call::Resolve, &tmp.join("gone"));
        let daemon = gated(&tmp, fs.clone());

        let before = std::time::Instant::now();
        let opens = [spawn_open(&daemon, &doc), spawn_open(&daemon, &doc)];
        for open in opens {
            assert_eq!(open.await.unwrap(), did_not_answer(&daemon, &doc));
        }
        assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
        assert_eq!(fs.calls(Call::Resolve), 1);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_open_during_a_look_at_its_path_makes_no_call_of_its_own() {
        let tmp = canon_tmp("open-during-look");
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, _release) = stuck_fs();
        let daemon = gated(&tmp, fs.clone());
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        fs.hold(Call::Resolve, &tmp.join("gone"));
        fs.hold(Call::Stamp, &tmp.join("gone"));

        let look = tokio::spawn({
            let (daemon, doc) = (daemon.clone(), doc.clone());
            async move { daemon.look(|_| vec![doc], |_, now| now.clone()).await }
        });
        eventually("the held read", || fs.held(Call::Stamp) == 1).await;
        let before = std::time::Instant::now();
        assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
        assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
        assert_eq!(look.await.unwrap(), HashMap::new());
        assert_eq!(fs.held(Call::Resolve) + fs.held(Call::Stamp), 1);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // The second caller waits for the call there, then makes its own.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_second_open_of_a_path_that_answers_in_time_succeeds_too() {
        let tmp = canon_tmp("open-twice-healthy");
        let doc = write_doc(tmp.join("d/a.md"));
        let (fs, release) = stuck_fs();
        fs.hold(Call::Resolve, &tmp.join("d"));
        let daemon = gated(&tmp, fs.clone());

        let first = spawn_open(&daemon, &doc);
        eventually("the held resolve", || fs.held(Call::Resolve) == 1).await;
        let second = spawn_open(&daemon, &doc);
        // Time for the second open to reach the call of the first. It passes
        // either way; the wait is what it is there to try.
        tokio::time::sleep(LIMIT / 4).await;
        drop(release);
        assert_eq!(first.await.unwrap(), Ok(()));
        assert_eq!(second.await.unwrap(), Ok(()));
        assert_eq!(fs.calls(Call::Resolve), 2);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_call_that_panics_after_its_limit_ends_its_key() {
        let tmp = tmp_dir("panics");
        let doc = write_doc(tmp.join("gone/a.md"));
        let (fs, release) = stuck_fs();
        fs.hold(Call::Stamp, &tmp.join("gone"));
        let returned = Arc::new(AtomicU32::new(0));
        let gate = Arc::new(PathGate::new(fs, LIMIT, {
            let returned = returned.clone();
            Arc::new(move || {
                returned.fetch_add(1, Ordering::SeqCst);
            })
        }));

        let (calling, key) = (gate.clone(), doc.clone());
        let ran = answers(async move {
            let path = key.clone();
            calling
                .run(&key, move |fs: &dyn PathFs| -> Option<FileStamp> {
                    fs.stamp(&path);
                    panic!("the call panics")
                })
                .await
        });
        assert!(ran.await.is_err());

        drop(release);
        eventually("the end of the call", || returned.load(Ordering::SeqCst) == 1).await;
        assert!(!gate.is_out_dir(&tmp.join("gone")));
        let (calling, key) = (gate.clone(), doc.clone());
        let again = answers(async move {
            let path = key.clone();
            calling.run(&key, move |fs| fs.stamp(&path)).await
        });
        assert_eq!(again.await.unwrap(), crate::reader::stamp(&doc));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // The open reads the doc's stamp before it registers the doc. In a dir
    // that is already watched no look follows the open, and the wake of the
    // change can come before the doc is registered.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_change_between_the_stamp_and_the_upsert_of_an_open_is_pushed() {
        let (tmp, _, daemon, fs, release) = in_a_repo("open-window").await;
        let mut app = connect_app(&daemon).await;
        let doc = write_doc(tmp.join("d/b.md"));
        fs.hold(Call::RepoOf, &doc);

        let opening = spawn_open(&daemon, &doc);
        eventually("the held walk", || fs.held(Call::RepoOf) == 1).await;
        let changed = change(&doc);
        drop(release);
        assert_eq!(opening.await.unwrap(), Ok(()));
        let event = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                match app.recv().await {
                    Some(Msg::FileEvent { path, mtime_ms }) => return (PathBuf::from(path), mtime_ms),
                    Some(_) => {}
                    None => panic!("the app went away"),
                }
            }
        });
        assert_eq!(event.await.expect("a file_event"), (doc, changed));

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
