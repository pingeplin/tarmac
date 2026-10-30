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
    pub async fn new(state_path: PathBuf) -> anyhow::Result<Arc<Self>> {
        let wake = Arc::new(Notify::new());
        let source = NotifySource::new({
            let wake = wake.clone();
            move || wake.notify_one()
        })?;
        Ok(Self::with_source(state_path, Box::new(source), wake).await)
    }

    /// `source` is told which directories have a doc, and sets `wake` when a
    /// file in one of them may have changed.
    async fn with_source(state_path: PathBuf, source: Box<dyn WakeSource>, wake: Arc<Notify>) -> Arc<Self> {
        Self::with_fs(state_path, source, wake, Arc::new(RealFs), crate::reader::READ_LIMIT).await
    }

    /// `with_source`, whose gate makes its calls on `fs` and waits `limit`
    /// for each.
    async fn with_fs(
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
mod tests;
