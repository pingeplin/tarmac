//! What wakes the daemon to look at its docs. A wake carries no detail: the
//! daemon compares each doc with its file (`docs::report_changes`), so a
//! change whose wake was lost is reported at the next look, not never. The
//! source is called on one thread of its own (`Asks::spawn`), never by a
//! caller.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode, Watcher as _};
use tokio::sync::oneshot;

/// The burst window docs/protocol.md gives a `file_event`: how long
/// `docs::watch_loop` waits after a wake before it looks, and so the least
/// time between two of its looks.
pub const BURST: Duration = Duration::from_millis(100);

pub trait WakeSource: Send {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()>;
    fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()>;
}

/// FSEvents through `notify`. Each `watch` and `unwatch` restarts its one
/// stream, and the restart loses the events that the stream has not delivered
/// yet (#253): the watcher thread wakes a look after either. No debouncer
/// (#258).
pub struct NotifySource(RecommendedWatcher);

impl NotifySource {
    /// `wake` runs on the watcher's thread, for each event.
    pub fn new(wake: impl Fn() + Send + 'static) -> anyhow::Result<Self> {
        let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Err(error) = res {
                tracing::warn!("watch error: {error:?}");
            }
            wake();
        })?;
        Ok(NotifySource(watcher))
    }
}

impl WakeSource for NotifySource {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
        Ok(self.0.watch(dir, RecursiveMode::NonRecursive)?)
    }

    fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()> {
        Ok(self.0.unwatch(dir)?)
    }
}

/// Why a directory that is wanted is not watched.
pub enum NotWatched {
    /// A call on a path in it is out (`PathGate::is_out_dir`): it is not
    /// asked of the source until that call returns.
    Out,
    Refused(anyhow::Error),
}

/// `Ok(true)` when the source was called and the stream restarted.
pub type Answer = Result<bool, NotWatched>;

enum Ask {
    Reconcile(PathBuf, Option<oneshot::Sender<Answer>>),
    Retry,
    #[cfg(test)]
    Watched(PathBuf, oneshot::Sender<bool>),
}

/// The callers' end of the watcher thread (`Asks::spawn`). No call on it
/// waits for the thread; only an answer does.
#[derive(Clone)]
pub struct Watcher(mpsc::Sender<Ask>);

/// The thread's end, until it is spawned.
pub struct Asks(mpsc::Receiver<Ask>);

pub fn channel() -> (Watcher, Asks) {
    let (tx, rx) = mpsc::channel();
    (Watcher(tx), Asks(rx))
}

impl Watcher {
    /// Has the thread make the watch of `dir` follow whether it is wanted
    /// now. A request is not an edge: what the thread compares is the state
    /// when it comes to it.
    pub fn reconcile(&self, dir: &Path) {
        self.ask(dir, None);
    }

    /// `reconcile`, and its answer.
    pub fn answer(&self, dir: &Path) -> oneshot::Receiver<Answer> {
        let (tx, rx) = oneshot::channel();
        self.ask(dir, Some(tx));
        rx
    }

    fn ask(&self, dir: &Path, reply: Option<oneshot::Sender<Answer>>) {
        let _ = self.0.send(Ask::Reconcile(dir.to_owned(), reply));
    }

    /// Reconciles again each dir that was skipped while it was out.
    pub fn retry(&self) {
        let _ = self.0.send(Ask::Retry);
    }

    /// Whether `dir` is watched, once the thread has done what it was asked
    /// before.
    #[cfg(test)]
    pub async fn watched(&self, dir: &Path) -> bool {
        let (tx, rx) = oneshot::channel();
        let _ = self.0.send(Ask::Watched(dir.to_owned(), tx));
        rx.await.expect("the watcher thread answers")
    }
}

impl Asks {
    /// The one thread that calls `source`, one call at a time, so that a
    /// call that does not return (notify reads the path itself) holds only
    /// this thread. A dir is wanted while `wanted` says so; `woke` runs after
    /// each call of the source, which restarts the stream whether it
    /// succeeded or not (#253). It ends when every `Watcher` is dropped.
    pub fn spawn(
        self,
        source: Box<dyn WakeSource>,
        wanted: impl Fn(&Path) -> bool + Send + 'static,
        is_out: impl Fn(&Path) -> bool + Send + 'static,
        woke: impl Fn() + Send + 'static,
    ) {
        let mut thread = Thread { source, watched: HashSet::new(), retry: HashSet::new(), wanted, is_out, woke };
        std::thread::Builder::new()
            .name("tarmacd-watcher".into())
            .spawn(move || {
                let _said = SaysAPanic;
                while let Ok(ask) = self.0.recv() {
                    thread.take(ask);
                }
            })
            .expect("spawn the watcher thread");
    }
}

/// The thread is not started again: after a panic every open that needs a
/// new watch fails, and this is what says why.
struct SaysAPanic;

impl Drop for SaysAPanic {
    fn drop(&mut self) {
        if std::thread::panicking() {
            tracing::error!("the watcher thread panicked: no directory is watched or unwatched until a restart");
        }
    }
}

struct Thread<W, O, F> {
    source: Box<dyn WakeSource>,
    /// The dirs in the stream.
    watched: HashSet<PathBuf>,
    /// The dirs skipped while they were out.
    retry: HashSet<PathBuf>,
    wanted: W,
    is_out: O,
    woke: F,
}

impl<W: Fn(&Path) -> bool, O: Fn(&Path) -> bool, F: Fn()> Thread<W, O, F> {
    fn take(&mut self, ask: Ask) {
        match ask {
            Ask::Reconcile(dir, reply) => {
                let answer = self.reconcile(&dir);
                if let Some(reply) = reply {
                    let _ = reply.send(answer);
                }
            }
            Ask::Retry => {
                for dir in std::mem::take(&mut self.retry) {
                    let _ = self.reconcile(&dir);
                }
            }
            #[cfg(test)]
            Ask::Watched(dir, reply) => {
                let _ = reply.send(self.watched.contains(&dir));
            }
        }
    }

    fn reconcile(&mut self, dir: &Path) -> Answer {
        self.retry.remove(dir);
        let want = (self.wanted)(dir);
        if want == self.watched.contains(dir) {
            return Ok(false);
        }
        if (self.is_out)(dir) {
            self.retry.insert(dir.to_owned());
            return Err(NotWatched::Out);
        }
        let (verb, called) = if want {
            let called = self.source.watch(dir);
            if called.is_ok() {
                self.watched.insert(dir.to_owned());
            }
            ("watch", called)
        } else {
            // notify 8.2.0 takes the dir out of its stream before it fails
            // most unwatches (`FsEventWatcher::remove_path`), so a failed one
            // counts as done: a dir kept here would never be watched again.
            self.watched.remove(dir);
            ("unwatch", self.source.unwatch(dir))
        };
        (self.woke)();
        if let Err(e) = called {
            tracing::warn!("cannot {verb} {}: {e}", dir.display());
            return Err(NotWatched::Refused(e));
        }
        Ok(true)
    }
}
