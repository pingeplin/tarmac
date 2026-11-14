use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use tarmac_protocol::{DocEntry, Msg};
use tokio::sync::{Mutex, Notify, mpsc};
use tokio_util::sync::CancellationToken;

use crate::boards::{BoardId, Boards, DataDir, FileStamp, WantedData};
use crate::docs::RepoInfo;
use crate::reader::{PathFs, PathGate, RealFs};
use crate::term::TermHandle;
use crate::watch::{NotWatched, NotifySource, Wake, WakeSource, Watcher};

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
    wake: Arc<Wake>,
    /// One `look` at a time. Taken before `boards`, never while `boards` is
    /// held.
    looking: Mutex<()>,
    gate: Arc<PathGate>,
    next_generation: AtomicU64,
    dirty: Notify,
    /// Held by each state write; true once the final one is written.
    pub saves_stopped: Mutex<bool>,
    state_path: PathBuf,
}

impl Daemon {
    pub async fn new(state_path: PathBuf) -> anyhow::Result<Arc<Self>> {
        let wake = Arc::new(Wake::default());
        let source = NotifySource::new({
            let wake = wake.clone();
            move || wake.from_fs()
        })?;
        Ok(Self::with_source(state_path, Box::new(source), wake).await)
    }

    /// `source` is told which directories have a doc, and sets `wake` when a
    /// file in one of them may have changed.
    async fn with_source(state_path: PathBuf, source: Box<dyn WakeSource>, wake: Arc<Wake>) -> Arc<Self> {
        Self::with_fs(state_path, source, wake, Arc::new(RealFs), crate::reader::READ_LIMIT).await
    }

    /// `with_source`, whose gate makes its calls on `fs` and waits `limit`
    /// for each.
    async fn with_fs(
        state_path: PathBuf,
        source: Box<dyn WakeSource>,
        wake: Arc<Wake>,
        fs: Arc<dyn PathFs>,
        limit: std::time::Duration,
    ) -> Arc<Self> {
        let (watcher, asks) = crate::watch::channel();
        let gate = Arc::new(PathGate::new(fs, limit, {
            let (wake, watcher) = (wake.clone(), watcher.clone());
            Arc::new(move || {
                wake.from_fs();
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
                move || wake.from_daemon()
            },
        );
        let mut boards = crate::persist::load(&state_path);
        crate::docs::read_restored(&gate, &mut boards).await;
        // Every board's docs, not the active board's only: a switch adds no
        // watch. A dir that cannot be watched only loses file events; its docs
        // keep their counts, and the next open there asks for the watch again.
        // Sent after the reads, so that a dir whose read is out is not asked
        // of notify.
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
            saves_stopped: Mutex::new(false),
            state_path,
        });
        tokio::spawn(crate::docs::watch_loop(daemon.clone()));
        tokio::spawn(crate::persist::save_loop(daemon.clone()));
        daemon
    }

    pub fn gate(&self) -> &PathGate {
        &self.gate
    }

    /// True when a wake since the last one came from the file system.
    pub async fn woken(&self) -> bool {
        self.wake.woken().await
    }

    /// One look: reads the files of `paths` with no `boards` lock held, then
    /// gives the reading to `apply` under that lock. It is the one place that
    /// reads a doc's file or a data file for a change, and it runs one at a
    /// time, so that an older reading is never applied after a newer one.
    /// Nothing is pushed from inside it. A doc whose file could not be read in
    /// time (`PathGate`) is not in the reading.
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

    /// Counts the directory of `data`, the data file of `doc` (2611.0005),
    /// and has it watched. The directory is resolved first, on the gate: the
    /// counts and the watcher thread are keyed by a path's text, and notify
    /// by the resolved path, so a link would give one watch two texts and
    /// the unwatch of one would end the other. Nothing is counted for a file
    /// in the doc's own directory, which the doc counts, nor for a directory
    /// that resolves to that one, out of the doc's tree, or to a hidden name
    /// below it. A directory that cannot be resolved takes no count, and one
    /// whose watch fails gives its count back at once: both are `Wanted`.
    /// True with it when the stream restarted: the caller looks at the docs,
    /// as `open_doc` does.
    pub async fn count_data_dir(&self, doc: &Path, data: &Path) -> (DataDir, bool) {
        let (Some(doc_dir), Some(dir)) = (doc.parent(), data.parent()) else { return (DataDir::Uncounted, false) };
        if dir == doc_dir {
            return (DataDir::Uncounted, false);
        }
        let owned = dir.to_owned();
        let resolved = self.gate.run(dir, move |fs| fs.resolve_dir(&owned)).await;
        let Ok(Some(resolved)) = resolved else { return (DataDir::Wanted, false) };
        if !crate::docs::is_below(doc_dir, &resolved) {
            return (DataDir::Uncounted, false);
        }
        match self.acquire_watch(&resolved).await {
            Ok(watched) => (DataDir::Counted(resolved), watched),
            Err(e) => {
                tracing::debug!("the data directory is tried again at a wake of the file system: {e}");
                self.release_watch(&resolved);
                (DataDir::Wanted, false)
            }
        }
    }

    /// Gives back what a data registration counted.
    pub fn release_data_dir(&self, dir: &DataDir) {
        if let DataDir::Counted(dir) = dir {
            self.release_watch(dir);
        }
    }

    /// Gives back what a doc that is gone counted: its directory, and its
    /// data file's.
    fn release_doc(&self, path: &Path, info: &crate::boards::DocInfo) {
        if let Some(dir) = path.parent() {
            self.release_watch(dir);
        }
        if let Some(read) = &info.data {
            self.release_data_dir(&read.dir);
        }
    }

    /// Tries again the directory of each data file that wants one, on every
    /// board (2611.0005). Called at a wake of the file system only (`Wake`).
    /// A registration replaced, cleared or dropped during its try keeps
    /// nothing of it.
    pub async fn try_wanted_data(&self) {
        let wanted = self.boards.lock().await.wanted_data();
        for WantedData { board, doc, file } in wanted {
            let (dir, _) = self.count_data_dir(&doc, &file).await;
            let not_held = match self.boards.lock().await.known_registry_mut(&board) {
                Some(reg) => reg.settle_wanted(&doc, &file, dir),
                None => dir,
            };
            self.release_data_dir(&not_held);
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
            self.wake.from_daemon();
        }
        Ok(entry)
    }

    /// Forgets a doc of the active board and takes it, and its data file's
    /// directory, off their counts. False for an unknown path.
    pub async fn close_doc(&self, path: &Path) -> bool {
        let closed = self.boards.lock().await.active_registry_mut().close_doc(path);
        let Some(info) = closed else { return false };
        self.mark_dirty();
        self.release_doc(path, &info);
        true
    }

    /// Removes a board and takes its docs, and their data files'
    /// directories, off their counts, dropping the watch of each directory
    /// that is left empty. False for the last board or an unknown id. It does
    /// not look at the docs: its caller sends the active board next, and that
    /// send looks (`conn::change_and_send_active_board`), and the watcher
    /// thread wakes a look after its unwatches.
    pub async fn delete_board(&self, id: &str) -> bool {
        let deleted = self.boards.lock().await.delete(id);
        let Some(board) = deleted else { return false };
        self.mark_dirty();
        for (path, info) in &board.registry.docs {
            self.release_doc(path, info);
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

    /// The connection takes the app's place. The data registrations of the
    /// one it replaces are dropped while the place is held, so that none of
    /// its own is: the app names each file again when it connects (2611.0005).
    pub async fn install_app(
        &self,
        tx: mpsc::Sender<Msg>,
        version: Option<String>,
    ) -> (u64, CancellationToken) {
        let cancel = CancellationToken::new();
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        let mut slot = self.app.lock().await;
        let old = slot.replace(AppSlot {
            generation,
            tx,
            cancel: cancel.clone(),
            version,
        });
        if let Some(old) = old {
            tracing::info!("replacing previous app connection");
            old.cancel.cancel();
            self.drop_data().await;
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

    /// The connection `generation` ends. When it holds the app's place, the
    /// place is left and the data registrations are dropped, with the place
    /// held: a connection that took the place meanwhile loses nothing.
    pub async fn remove_app(&self, generation: u64) {
        let mut slot = self.app.lock().await;
        if slot.as_ref().is_some_and(|s| s.generation == generation) {
            *slot = None;
            self.drop_data().await;
        }
    }

    /// Drops every data registration of every board, with its count. Takes
    /// `boards` with `app` held: no path holds `boards` and then takes `app`.
    async fn drop_data(&self) {
        let dropped = self.boards.lock().await.drop_data();
        for dir in &dropped {
            self.release_data_dir(dir);
        }
    }

    /// Files a new terminal under `board` with its record: the record of
    /// `succeeds` when that board has one and the term is not live, else an
    /// empty one. Runs before the terminal's first cwd read, which only ever
    /// fills a record that is there.
    pub async fn adopt_term(&self, term_id: &str, board: &str, succeeds: Option<&str>) {
        let succeeds = match succeeds {
            Some(old) if !self.terms.lock().await.contains_key(old) => Some(old),
            _ => None,
        };
        self.term_boards.lock().await.insert(term_id.to_owned(), board.to_owned());
        let mut boards = self.boards.lock().await;
        let Some(reg) = boards.known_registry_mut(board) else { return };
        let moved = succeeds.and_then(|old| reg.term_records.remove(old));
        if moved.is_some() {
            self.mark_dirty();
        }
        reg.term_records.insert(term_id.to_owned(), moved.unwrap_or_default());
    }

    /// Stores `cwd` in the record of a live `term_id`, on its own board. A
    /// record that is gone (closed, ended cleanly, or its board deleted) is
    /// not made again. Not saved by itself.
    pub async fn record_cwd(&self, term_id: &str, cwd: String) {
        if !self.terms.lock().await.contains_key(term_id) {
            return;
        }
        let Some(board) = self.term_boards.lock().await.get(term_id).cloned() else { return };
        let mut boards = self.boards.lock().await;
        if let Some(record) = boards.known_registry_mut(&board).and_then(|reg| reg.term_records.get_mut(term_id)) {
            record.last_cwd = Some(cwd);
        }
    }

    /// Deletes the record of `term_id`, live or not, and kills its process
    /// group when it is live.
    pub async fn close_term(&self, term_id: &str) {
        if self.boards.lock().await.forget_term(term_id) {
            self.mark_dirty();
        }
        match self.term(term_id).await {
            Some(h) => h.kill(),
            None => tracing::debug!("term_close for unknown term {term_id}"),
        }
    }

    /// Takes an exited terminal out of the maps. A clean exit (`Some(0)`)
    /// deletes its record; any other keeps it for the dead card.
    pub async fn term_ended(&self, term_id: &str, code: Option<i64>) {
        if self.terms.lock().await.remove(term_id).is_none() {
            tracing::warn!("term {term_id} missing from registry at exit");
        }
        let board = self.term_boards.lock().await.remove(term_id);
        let (Some(board), Some(0)) = (board, code) else { return };
        let forgot = self.boards.lock().await.known_registry_mut(&board).is_some_and(|reg| reg.term_records.remove(term_id).is_some());
        if forgot {
            self.mark_dirty();
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
mod tests;
