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
use crate::watch::{NotWatched, NotifySource, WakeSource, Watcher};

pub struct AppSlot {
    pub generation: u64,
    pub tx: mpsc::Sender<Msg>,
    pub cancel: CancellationToken,
    /// What the app reported in its `hello`. `None` means the app connected
    /// without naming a version, which is NOT the same as no app — slot
    /// occupancy is the separate fact `app_slot_version` reports first.
    pub version: Option<String>,
}

/// The registered docs in each directory, one for each board that has the
/// doc. The watcher thread watches a directory while it has a count. The lock
/// is held for a map update only.
#[derive(Default)]
struct DocCounts(std::sync::Mutex<HashMap<PathBuf, usize>>);

impl DocCounts {
    /// True when it is the first registered doc in `dir`.
    fn count(&self, dir: &Path) -> bool {
        let mut counts = self.0.lock().expect("doc counts lock");
        let count = counts.entry(dir.to_owned()).or_default();
        *count += 1;
        *count == 1
    }

    /// True when that was the last registered doc in `dir`.
    fn uncount(&self, dir: &Path) -> bool {
        let mut counts = self.0.lock().expect("doc counts lock");
        let Some(count) = counts.get_mut(dir) else { return false };
        *count -= 1;
        if *count > 0 {
            return false;
        }
        counts.remove(dir);
        true
    }

    fn has(&self, dir: &Path) -> bool {
        self.0.lock().expect("doc counts lock").contains_key(dir)
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
    doc_counts: Arc<DocCounts>,
    watcher: Watcher,
    /// Set by the watcher; `docs::watch_loop` waits on it.
    wake: Arc<Notify>,
    /// One `look` at a time. Taken before `boards`, never while `boards` is
    /// held.
    looking: Mutex<()>,
    gate: Arc<PathGate>,
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
        let (watcher, asks) = crate::watch::channel();
        let gate = Arc::new(PathGate::new(fs, limit, {
            let (wake, watcher) = (wake.clone(), watcher.clone());
            Arc::new(move || {
                wake.notify_one();
                watcher.retry();
            })
        }));
        let doc_counts = Arc::new(DocCounts::default());
        // The thread holds the gate weakly: the gate's `returned` holds a
        // `Watcher`, and the thread ends when the last one is dropped.
        asks.spawn(
            source,
            {
                let doc_counts = doc_counts.clone();
                move |dir| doc_counts.has(dir)
            },
            {
                let gate = Arc::downgrade(&gate);
                move |dir| gate.upgrade().is_some_and(|gate| gate.is_out_dir(dir))
            },
            {
                let wake = wake.clone();
                move || wake.notify_one()
            },
        );
        let boards = crate::persist::load(&state_path);
        // Every board's docs, not the active board's only: a switch adds no
        // watch. A dir that cannot be watched only loses file events; its docs
        // keep their counts, and the next open there asks for the watch again.
        for dir in boards.iter().flat_map(|b| b.registry.docs.keys()).filter_map(|p| p.parent()) {
            if doc_counts.count(dir) {
                watcher.reconcile(dir);
            }
        }
        let daemon = Arc::new(Daemon {
            app: Mutex::new(None),
            boards: Mutex::new(boards),
            terms: Mutex::new(HashMap::new()),
            term_boards: Mutex::new(HashMap::new()),
            doc_counts,
            watcher,
            wake,
            looking: Mutex::new(()),
            gate,
            next_generation: AtomicU64::new(1),
            dirty: Notify::new(),
            state_path,
        });
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

    /// Counts one more registered doc in `dir`, and has the watcher thread
    /// watch the directory. The first doc of `dir` waits for the thread's
    /// answer, within the gate's limit. Any other does not: a directory whose
    /// watch failed at startup is watched then, and the thread wakes the look.
    /// The count stands when the watch fails, so each call is paired with one
    /// `release_watch`.
    ///
    /// True when it watched: the stream restarted (`NotifySource`), and the
    /// caller looks at the docs itself (`docs::report_changes`).
    async fn acquire_watch(&self, dir: &Path) -> Result<bool, String> {
        if !self.doc_counts.count(dir) {
            self.watcher.reconcile(dir);
            return Ok(false);
        }
        match tokio::time::timeout(self.gate.limit(), self.watcher.answer(dir)).await {
            Ok(Ok(Ok(watched))) => Ok(watched),
            Ok(Ok(Err(NotWatched::Refused(e)))) => Err(format!("cannot watch {}: {e}", dir.display())),
            _ => Err(self.gate.did_not_answer(&format!("cannot watch {}", dir.display()))),
        }
    }

    /// Takes one registered doc off the count of `dir`, and has the watcher
    /// thread drop the watch with the last one. It does not wait: the
    /// thread's wake gives the look that follows the unwatch.
    fn release_watch(&self, dir: &Path) {
        if self.doc_counts.uncount(dir) {
            self.watcher.reconcile(dir);
        }
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
        let watched = match self.acquire_watch(dir).await {
            Ok(watched) => watched,
            Err(e) => {
                self.release_watch(dir);
                anyhow::bail!(e);
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
        } else if is_new {
            // A repair, on purpose: `seen` was read before the doc was
            // registered, and the wake of a change in between could come
            // before it too. A re-open keeps what was seen and needs none.
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
        if let Some(dir) = path.parent() {
            self.release_watch(dir);
        }
        true
    }

    /// Removes a board and takes its docs off their directories' counts,
    /// dropping the watch of each directory that is left empty. False for the
    /// last board or an unknown id. It does not look at the docs: its caller
    /// sends the active board next, and that send looks
    /// (`conn::change_and_send_active_board`), and the watcher thread wakes a
    /// look after its unwatches.
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

    async fn watched(daemon: &Daemon, dir: &Path) -> bool {
        tokio::time::timeout(Duration::from_secs(5), daemon.watcher.watched(dir)).await.expect("the watcher answers")
    }

    fn count(daemon: &Daemon, dir: &Path) -> usize {
        daemon.doc_counts.0.lock().unwrap().get(dir).copied().unwrap_or(0)
    }

    #[tokio::test]
    async fn a_dir_is_watched_from_its_first_count_to_its_last() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("count");

        daemon.acquire_watch(&doc_dir).await.unwrap();
        daemon.acquire_watch(&doc_dir).await.unwrap();
        assert!(watched(&daemon, &doc_dir).await);

        daemon.release_watch(&doc_dir);
        assert!(watched(&daemon, &doc_dir).await, "one doc is left");
        daemon.release_watch(&doc_dir);
        assert!(!watched(&daemon, &doc_dir).await);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn closing_the_sole_doc_of_a_dir_unwatches_it() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("close-sole");
        let doc = doc_dir.join("a.md");
        open_doc(&daemon, None, &doc).await;
        assert!(watched(&daemon, &doc_dir).await);
        assert!(!watched(&daemon, &tmp).await, "a doc in a subdirectory does not count");

        assert!(daemon.close_doc(&doc).await);
        assert!(!watched(&daemon, &doc_dir).await);
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
        assert!(watched(&daemon, &doc_dir).await);

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
        assert!(watched(&daemon, &doc_dir).await, "board-0 still has a doc in the directory");

        daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);
        assert!(daemon.close_doc(&doc_a).await);
        assert!(!watched(&daemon, &doc_dir).await, "no board has a doc in the directory");

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
        assert!(!watched(&daemon, &own).await, "no board is left with a doc there");
        assert!(watched(&daemon, &shared).await, "board-0 still has a doc there");
        assert!(!daemon.delete_board(&other).await, "a second delete finds no board");

        assert!(daemon.close_doc(&shared.join("a.md")).await);
        assert!(!watched(&daemon, &shared).await);
        assert!(daemon.doc_counts.0.lock().unwrap().is_empty(), "no count is left at zero");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn reopening_a_doc_counts_it_once() {
        let (tmp, doc_dir, daemon) = daemon_with_doc_dir("reopen");
        let doc = doc_dir.join("a.md");
        open_doc(&daemon, None, &doc).await;
        open_doc(&daemon, None, &doc).await;

        assert!(daemon.close_doc(&doc).await);
        assert!(!watched(&daemon, &doc_dir).await);

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
        assert!(!watched(&daemon, &late_dir).await, "the failed open left no count");

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
        assert!(watched(&daemon, &doc_dir).await);

        assert!(daemon.close_doc(&a).await);
        assert!(watched(&daemon, &doc_dir).await, "b.md is left");
        assert!(daemon.close_doc(&b).await);
        assert!(!watched(&daemon, &doc_dir).await);

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
        assert!(!watched(&daemon, &doc_dir).await);

        std::fs::create_dir_all(&doc_dir).unwrap();
        open_doc(&daemon, None, &b).await;
        assert!(watched(&daemon, &doc_dir).await);
        assert!(daemon.close_doc(&b).await);
        assert!(watched(&daemon, &doc_dir).await, "a.md is left");
        assert!(daemon.close_doc(&a).await);
        assert!(!watched(&daemon, &doc_dir).await);

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

    /// The next `file_event`, past the other pushes.
    async fn next_change(app: &mut mpsc::Receiver<Msg>) -> (PathBuf, u64) {
        let event = async {
            loop {
                match app.recv().await {
                    Some(Msg::FileEvent { path, mtime_ms }) => return (PathBuf::from(path), mtime_ms),
                    Some(_) => {}
                    None => panic!("the app went away"),
                }
            }
        };
        tokio::time::timeout(Duration::from_secs(5), event).await.expect("a file_event")
    }

    /// 2610.0012's Flushed rule: an open that watched, or that registered a
    /// doc in a watched dir, wakes a look `BURST` later, which could push what
    /// the act of the test is to push. A change of `doc` waits for that look.
    async fn flushed(app: &mut mpsc::Receiver<Msg>, doc: &Path) {
        let changed = change(doc);
        assert_eq!(next_change(app).await, (doc.to_owned(), changed), "the look of the open");
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

    /// The pushes the app has now.
    fn pushed(app: &mut mpsc::Receiver<Msg>) -> Vec<Msg> {
        std::iter::from_fn(|| app.try_recv().ok()).collect()
    }

    fn file_events(app: &mut mpsc::Receiver<Msg>) -> Vec<(PathBuf, u64)> {
        let event = |msg| match msg {
            Msg::FileEvent { path, mtime_ms } => Some((PathBuf::from(path), mtime_ms)),
            _ => None,
        };
        pushed(app).into_iter().filter_map(event).collect()
    }

    // #253: an unwatch restarts the FSEvents stream, and the restart loses the
    // events that the stream has not delivered yet. So the watcher thread
    // wakes a look after the unwatch; here no other wake comes at all.
    #[tokio::test]
    async fn a_close_reports_a_change_that_no_wake_told_of() {
        let (tmp, daemon, mut app) = silent_daemon("close-reports").await;
        let kept = write_doc(tmp.join("kept/a.md"));
        let gone = write_doc(tmp.join("gone/b.md"));
        open_doc(&daemon, None, &kept).await;
        flushed(&mut app, &kept).await;
        open_doc(&daemon, None, &gone).await;
        flushed(&mut app, &gone).await;

        let changed = change(&kept);
        assert!(daemon.close_doc(&gone).await);
        assert_eq!(next_change(&mut app).await, (kept, changed));

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
        flushed(&mut app, &kept).await;

        let changed = change(&kept);
        assert!(daemon.open_doc(None, &write_doc(refused.join("b.md")), "t", None, None, None).await.is_err());
        assert_eq!(next_change(&mut app).await, (kept, changed));

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
            assert!(watched(&daemon, &doc_dir).await, "round {round}: b.md is registered");

            assert!(daemon.close_doc(&b).await);
            assert!(!watched(&daemon, &doc_dir).await, "round {round}: no doc is left");
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
        /// Each method's calls, and how many of them it held.
        counts: std::sync::Mutex<HashMap<Call, (u32, u32)>>,
    }

    impl StuckFs {
        /// Holds each later `call` on a path under `under`.
        fn hold(&self, call: Call, under: &Path) {
            self.holds.lock().unwrap().push((call, under.to_owned()));
        }

        fn wait_if_held(&self, call: Call, path: &Path) {
            let held = self.holds.lock().unwrap().iter().any(|(c, under)| *c == call && path.starts_with(under));
            let mut counts = self.counts.lock().unwrap();
            let count = counts.entry(call).or_default();
            count.0 += 1;
            count.1 += u32::from(held);
            drop(counts);
            if held {
                let _ = self.until_released.lock().unwrap().recv();
            }
        }

        fn calls(&self, call: Call) -> u32 {
            self.counts.lock().unwrap().get(&call).map_or(0, |count| count.0)
        }

        fn held(&self, call: Call) -> u32 {
            self.counts.lock().unwrap().get(&call).map_or(0, |count| count.1)
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
            counts: std::sync::Mutex::default(),
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
        let opened = |msg| match msg {
            Msg::DocOpened(entry) => Some(PathBuf::from(entry.path)),
            _ => None,
        };
        pushed(app).into_iter().filter_map(opened).collect()
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
        // Time for the second open to reach the call of the first, and less
        // than the limit that it waits for it.
        tokio::time::sleep(LIMIT / 4).await;
        assert!(!second.is_finished(), "the second open did not wait for the first");
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
        let tmp = canon_tmp("open-window");
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        let open = write_doc(tmp.join("d/a.md"));
        let (fs, release) = stuck_fs();
        // A limit that the held walk cannot reach: a walk that is out wakes a
        // look of its own when it returns.
        let daemon =
            Daemon::with_fs(tmp.join("state.json"), Box::new(Silent), Arc::new(Notify::new()), fs.clone(), Duration::from_secs(30));
        assert_eq!(try_open(&daemon, &open).await, Ok(()));
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

    // A re-open keeps what was seen (`upsert_doc`): a look after it would
    // read every doc of the board for nothing.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_reopen_in_a_watched_dir_wakes_no_look() {
        let tmp = canon_tmp("reopen-no-look");
        let doc = write_doc(tmp.join("d/a.md"));
        let (fs, _release) = stuck_fs();
        let daemon = gated(&tmp, fs.clone());
        let mut app = connect_app(&daemon).await;
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        flushed(&mut app, &doc).await;
        let reads = fs.calls(Call::Stamp);

        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        tokio::time::sleep(3 * crate::watch::BURST).await;
        assert_eq!(fs.calls(Call::Stamp), reads, "a look read the docs");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    enum Change {
        Watch,
        Unwatch,
    }

    /// The calls a `HeldSource` was given, held or not.
    #[derive(Default)]
    struct SourceCalls(std::sync::Mutex<Vec<(Change, PathBuf)>>);

    impl SourceCalls {
        fn of(&self, change: Change, dir: &Path) -> usize {
            self.0.lock().unwrap().iter().filter(|(c, d)| *c == change && d == dir).count()
        }
    }

    /// A source that records each call, and holds those the test names until
    /// the sender of `until_released` is dropped: a notify that does not
    /// return.
    struct HeldSource {
        calls: Arc<SourceCalls>,
        holds: Vec<(Change, PathBuf)>,
        until_released: std::sync::mpsc::Receiver<()>,
    }

    impl HeldSource {
        fn call(&mut self, change: Change, dir: &Path) -> anyhow::Result<()> {
            self.calls.0.lock().unwrap().push((change, dir.to_owned()));
            if self.holds.iter().any(|(c, d)| *c == change && d == dir) {
                let _ = self.until_released.recv();
            }
            Ok(())
        }
    }

    impl WakeSource for HeldSource {
        fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
            self.call(Change::Watch, dir)
        }

        fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()> {
            self.call(Change::Unwatch, dir)
        }
    }

    /// The test holds the sender to its end, as for `stuck_fs`.
    fn held_source(holds: &[(Change, &Path)]) -> (Box<dyn WakeSource>, Arc<SourceCalls>, std::sync::mpsc::Sender<()>) {
        let (release, until_released) = std::sync::mpsc::channel();
        let calls = Arc::new(SourceCalls::default());
        let holds = holds.iter().map(|(c, d)| (*c, d.to_path_buf())).collect();
        (Box::new(HeldSource { calls: calls.clone(), holds, until_released }), calls, release)
    }

    /// A daemon whose watcher is `source` and whose gate calls `fs`.
    fn held(tmp: &Path, source: Box<dyn WakeSource>, fs: Arc<StuckFs>) -> Arc<Daemon> {
        Daemon::with_fs(tmp.join("state.json"), source, Arc::new(Notify::new()), fs, LIMIT)
    }

    fn cannot_watch(daemon: &Daemon, dir: &Path) -> Result<(), String> {
        let answer = daemon.gate().did_not_answer(&format!("cannot watch {}", dir.display()));
        assert!(answer.starts_with(&format!("cannot watch {}: did not answer in ", dir.display())));
        Err(answer)
    }

    async fn within<T>(task: tokio::task::JoinHandle<T>) -> T {
        tokio::time::timeout(Duration::from_secs(2), task).await.expect("an answer").unwrap()
    }

    async fn try_close(daemon: &Arc<Daemon>, doc: &Path) -> bool {
        let (daemon, doc) = (daemon.clone(), doc.to_owned());
        answers(async move { daemon.close_doc(&doc).await }).await
    }

    // 2610.0012 S5b (D9): a walk that is out makes its dir out, and a dir that
    // is out is not watched.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_new_dir_whose_repo_does_not_answer_fails_the_open() {
        let tmp = canon_tmp("walk-stuck-new-dir");
        let gone = tmp.join("gone");
        let doc = write_doc(gone.join("b.md"));
        let (fs, _release) = stuck_fs();
        fs.hold(Call::RepoOf, &gone);
        let (source, calls, _unheld) = held_source(&[]);
        let daemon = held(&tmp, source, fs);

        let before = std::time::Instant::now();
        assert_eq!(try_open(&daemon, &doc).await, cannot_watch(&daemon, &gone));
        assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
        assert!(!registered(&daemon, &doc).await);
        assert_eq!(count(&daemon, &gone), 0);
        assert!(!watched(&daemon, &gone).await);
        assert_eq!(calls.of(Change::Watch, &gone), 0);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S9
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_close_whose_unwatch_does_not_return_answers_at_once() {
        let tmp = canon_tmp("unwatch-stuck");
        let (gone, d) = (tmp.join("gone"), tmp.join("d"));
        let (stuck, open) = (write_doc(gone.join("a.md")), write_doc(d.join("a.md")));
        let doc = write_doc(d.join("b.md"));
        let (fs, _unheld) = stuck_fs();
        let (source, calls, _release) = held_source(&[(Change::Unwatch, &gone)]);
        let daemon = held(&tmp, source, fs);
        assert_eq!(try_open(&daemon, &stuck).await, Ok(()));
        assert_eq!(try_open(&daemon, &open).await, Ok(()));

        let before = std::time::Instant::now();
        assert!(try_close(&daemon, &stuck).await);
        assert!(before.elapsed() < LIMIT, "the close waited {:?}", before.elapsed());
        eventually("the held unwatch", || calls.of(Change::Unwatch, &gone) == 1).await;

        let before = std::time::Instant::now();
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert!(before.elapsed() < LIMIT, "the open waited {:?}", before.elapsed());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S10: the bounded part of the Riskiest assumption.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_watch_that_does_not_return_fails_only_the_opens_that_need_it() {
        let tmp = canon_tmp("watch-stuck");
        let new = tmp.join("new");
        let doc = write_doc(new.join("b.md"));
        let (kept, other) = (write_doc(tmp.join("kept/a.md")), write_doc(tmp.join("other/c.md")));
        let (fs, _unheld) = stuck_fs();
        let (source, calls, release) = held_source(&[(Change::Watch, &new)]);
        let daemon = held(&tmp, source, fs);
        assert_eq!(try_open(&daemon, &kept).await, Ok(()));
        assert_eq!(try_open(&daemon, &other).await, Ok(()));

        let opened = std::time::Instant::now();
        let opening = spawn_open(&daemon, &doc);
        eventually("the held watch", || calls.of(Change::Watch, &new) == 1).await;
        let before = std::time::Instant::now();
        assert!(try_close(&daemon, &other).await);
        look_at(&daemon).await;
        assert!(before.elapsed() < LIMIT, "the close and the look waited {:?}", before.elapsed());

        assert_eq!(within(opening).await, cannot_watch(&daemon, &new));
        assert!(opened.elapsed() < 3 * LIMIT, "the open waited {:?}", opened.elapsed());
        assert!(!registered(&daemon, &doc).await);

        drop(release);
        assert!(!watched(&daemon, &new).await, "the failed open left no count");
        assert_eq!(calls.of(Change::Unwatch, &new), 1);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S11: a dir that is out waits for its call, the close side.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_dir_that_is_out_is_unwatched_when_its_call_returns() {
        let tmp = canon_tmp("unwatch-out");
        let gone = tmp.join("gone");
        let (stuck, doc) = (write_doc(gone.join("a.md")), write_doc(tmp.join("d/b.md")));
        let (fs, release) = stuck_fs();
        let (source, calls, _unheld) = held_source(&[]);
        let daemon = held(&tmp, source, fs.clone());
        let mut app = connect_app(&daemon).await;
        assert_eq!(try_open(&daemon, &stuck).await, Ok(()));
        flushed(&mut app, &stuck).await;
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        flushed(&mut app, &doc).await;
        fs.hold(Call::Stamp, &gone);
        look_at(&daemon).await;
        assert_eq!(fs.held(Call::Stamp), 1);

        assert!(try_close(&daemon, &stuck).await);
        assert!(watched(&daemon, &gone).await);
        assert_eq!(calls.of(Change::Unwatch, &gone), 0);

        let changed = change(&doc);
        drop(release);
        assert_eq!(next_change(&mut app).await, (doc, changed));
        eventually("the unwatch", || calls.of(Change::Unwatch, &gone) == 1).await;
        assert!(!watched(&daemon, &gone).await);
        assert_eq!(calls.of(Change::Unwatch, &gone), 1);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S11, the open side: the open's resolve is out, keyed in `gone`.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_new_doc_in_a_dir_that_is_out_fails_at_once() {
        let tmp = canon_tmp("watch-out");
        let gone = tmp.join("gone");
        let (stuck, doc) = (write_doc(gone.join("a.md")), write_doc(gone.join("b.md")));
        let (fs, _release) = stuck_fs();
        fs.hold(Call::Resolve, &stuck);
        let (source, calls, _unheld) = held_source(&[]);
        let daemon = held(&tmp, source, fs.clone());
        assert_eq!(try_open(&daemon, &stuck).await, did_not_answer(&daemon, &stuck));

        let before = std::time::Instant::now();
        assert_eq!(try_open(&daemon, &doc).await, cannot_watch(&daemon, &gone));
        assert!(before.elapsed() < LIMIT, "it waited {:?}", before.elapsed());
        assert_eq!(fs.calls(Call::Resolve), 2, "the doc was resolved");
        assert!(!registered(&daemon, &doc).await);
        assert!(!watched(&daemon, &gone).await);
        assert_eq!(calls.of(Change::Watch, &gone), 0);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S12: the thread compares the count with the watch when it
    // comes to the dir, not when it was asked.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_reopen_behind_a_pending_unwatch_keeps_its_dir_watched() {
        let tmp = canon_tmp("reopen-pending");
        let (x, d) = (tmp.join("x"), tmp.join("d"));
        let (busy, doc) = (write_doc(x.join("a.md")), write_doc(d.join("a.md")));
        let (fs, _unheld) = stuck_fs();
        let (source, calls, release) = held_source(&[(Change::Unwatch, &x)]);
        // A limit that the release after the poll below cannot miss.
        let daemon = Daemon::with_fs(tmp.join("state.json"), source, Arc::new(Notify::new()), fs, Duration::from_secs(30));
        assert_eq!(try_open(&daemon, &busy).await, Ok(()));
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert!(try_close(&daemon, &busy).await);
        eventually("the held unwatch", || calls.of(Change::Unwatch, &x) == 1).await;
        assert!(try_close(&daemon, &doc).await);

        let reopening = spawn_open(&daemon, &doc);
        eventually("the count of the re-open", || count(&daemon, &d) == 1).await;
        drop(release);
        assert_eq!(within(reopening).await, Ok(()));
        assert!(watched(&daemon, &d).await);
        assert_eq!(calls.of(Change::Unwatch, &d), 0);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S14: the first open released its count, so the second asks
    // for the watch again.
    #[tokio::test]
    async fn an_open_whose_watch_is_refused_fails_each_time_and_wakes_a_look() {
        let tmp = tmp_dir("refused-twice");
        let refused = tmp.join("refused");
        let daemon =
            Daemon::with_source(tmp.join("state.json"), Box::new(RefusesDir(refused.clone())), Arc::new(Notify::new()));
        let mut app = connect_app(&daemon).await;
        let kept = write_doc(tmp.join("kept/a.md"));
        open_doc(&daemon, None, &kept).await;
        flushed(&mut app, &kept).await;
        let doc = write_doc(refused.join("b.md"));
        let refusal = format!("cannot watch {}: refused", refused.display());

        let changed = change(&kept);
        let first = daemon.open_doc(None, &doc, "t", None, None, None).await;
        assert_eq!(first.map_err(|e| e.to_string()).err(), Some(refusal.clone()));
        assert_eq!(next_change(&mut app).await, (kept.clone(), changed));

        let second = daemon.open_doc(None, &doc, "t", None, None, None).await;
        assert_eq!(second.map_err(|e| e.to_string()).err(), Some(refusal));
        assert!(!daemon.close_doc(&doc).await, "nothing was registered");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S16: `watch_loop`'s one permit folds the wakes of the three
    // unwatches into one look, or two when one comes during the look.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn deleting_a_board_looks_once_or_twice_for_its_unwatches() {
        let tmp = canon_tmp("delete-looks");
        let sentinel = write_doc(tmp.join("s/s.md"));
        let dirs: Vec<PathBuf> = ["a", "b", "c"].iter().map(|d| tmp.join(d)).collect();
        let (fs, _unheld) = stuck_fs();
        let (source, calls, _release) = held_source(&[]);
        let daemon = held(&tmp, source, fs.clone());
        let mut app = connect_app(&daemon).await;
        assert_eq!(try_open(&daemon, &sentinel).await, Ok(()));
        flushed(&mut app, &sentinel).await;
        let other = daemon.boards.lock().await.create();
        daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);
        for dir in &dirs {
            open_doc(&daemon, Some(&other), &write_doc(dir.join("1.md"))).await;
            flushed(&mut app, &sentinel).await;
        }
        let reads = fs.calls(Call::Stamp);

        assert!(daemon.delete_board(&other).await);
        for dir in &dirs {
            assert!(!watched(&daemon, dir).await);
            assert_eq!(calls.of(Change::Unwatch, dir), 1);
        }
        eventually("a look", || fs.calls(Call::Stamp) > reads).await;
        // Nothing to wait for: the time in which a third look would come.
        tokio::time::sleep(4 * crate::watch::BURST).await;
        let looks = fs.calls(Call::Stamp) - reads;
        assert!((1..=2).contains(&looks), "{looks} looks");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // 2610.0012 S21: `Daemon::new` is still sync, so it sends the startup
    // watches and does not wait for them.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_restart_does_not_wait_for_its_watches() {
        let tmp = canon_tmp("restart-held");
        let d = tmp.join("d");
        let doc = write_doc(d.join("a.md"));
        std::fs::write(tmp.join("state.json"), state_with_docs(&[&doc])).unwrap();
        let (fs, _unheld) = stuck_fs();
        let (source, calls, release) = held_source(&[(Change::Watch, &d)]);

        let before = std::time::Instant::now();
        let building = tokio::task::spawn_blocking({
            let tmp = tmp.clone();
            move || held(&tmp, source, fs)
        });
        let daemon = tokio::time::timeout(Duration::from_secs(2), building).await.expect("a daemon").unwrap();
        assert!(before.elapsed() < LIMIT, "it waited {:?}", before.elapsed());
        assert!(registered(&daemon, &doc).await);

        drop(release);
        assert!(watched(&daemon, &d).await);
        assert_eq!(calls.of(Change::Watch, &d), 1);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // One `Retry` reconciles every dir that waits for it. A key that is a
    // dir (here the resolve of an open of a dir) makes it and its parent out
    // at once, and so its return sends one `Retry` for the two.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_retry_unwatches_every_dir_that_was_skipped() {
        let tmp = canon_tmp("retry-both");
        let (outer, inner) = (tmp.join("p"), tmp.join("p/q"));
        let docs = [write_doc(outer.join("a.md")), write_doc(inner.join("b.md"))];
        let (fs, release) = stuck_fs();
        let (source, calls, _unheld) = held_source(&[]);
        let daemon = held(&tmp, source, fs.clone());
        for doc in &docs {
            assert_eq!(try_open(&daemon, doc).await, Ok(()));
        }
        fs.hold(Call::Resolve, &inner);
        assert!(try_open(&daemon, &inner).await.is_err());
        assert!(daemon.gate().is_out_dir(&outer) && daemon.gate().is_out_dir(&inner));

        for doc in &docs {
            assert!(try_close(&daemon, doc).await);
        }
        assert!(watched(&daemon, &outer).await && watched(&daemon, &inner).await, "both are skipped");

        drop(release);
        eventually("both unwatches", || {
            calls.of(Change::Unwatch, &outer) == 1 && calls.of(Change::Unwatch, &inner) == 1
        })
        .await;

        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// Records each call; each unwatch fails.
    struct UnwatchFails(Arc<SourceCalls>);

    impl WakeSource for UnwatchFails {
        fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
            self.0.0.lock().unwrap().push((Change::Watch, dir.to_owned()));
            Ok(())
        }

        fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()> {
            self.0.0.lock().unwrap().push((Change::Unwatch, dir.to_owned()));
            anyhow::bail!("watch not found")
        }
    }

    // notify takes the dir out of its stream before it fails most unwatches
    // (`FsEventWatcher::remove_path`): a dir that is kept as watched would
    // never be watched again.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_dir_whose_unwatch_failed_is_watched_by_the_next_open() {
        let tmp = canon_tmp("unwatch-fails");
        let d = tmp.join("d");
        let doc = write_doc(d.join("a.md"));
        let calls = Arc::new(SourceCalls::default());
        let (fs, _unheld) = stuck_fs();
        let daemon = held(&tmp, Box::new(UnwatchFails(calls.clone())), fs);
        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert!(try_close(&daemon, &doc).await);
        assert!(!watched(&daemon, &d).await);
        assert_eq!(calls.of(Change::Unwatch, &d), 1);

        assert_eq!(try_open(&daemon, &doc).await, Ok(()));
        assert_eq!(calls.of(Change::Watch, &d), 2);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    struct Panics;

    impl WakeSource for Panics {
        fn watch(&mut self, _: &Path) -> anyhow::Result<()> {
            panic!("the source panics")
        }

        fn unwatch(&mut self, _: &Path) -> anyhow::Result<()> {
            Ok(())
        }
    }

    #[derive(Clone, Default)]
    struct Log(Arc<std::sync::Mutex<Vec<u8>>>);

    impl std::io::Write for Log {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    // After a panic every first open fails: the log is the one place that
    // says why. The watcher thread has no subscriber of its own, so this test
    // sets the global one; no other test of this binary sets one.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_watcher_thread_that_panics_logs_an_error() {
        let log = Log::default();
        let writer = log.clone();
        tracing_subscriber::fmt()
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .with_max_level(tracing::Level::ERROR)
            .init();
        let tmp = canon_tmp("watcher-panics");
        let doc = write_doc(tmp.join("d/a.md"));
        let (fs, _unheld) = stuck_fs();
        let daemon = held(&tmp, Box::new(Panics), fs);

        assert!(try_open(&daemon, &doc).await.is_err());
        let logged = || String::from_utf8_lossy(&log.0.lock().unwrap()).contains("the watcher thread panicked");
        eventually("the error", logged).await;

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
