//! Every file-system call on a doc's path, on blocking threads, with a time
//! limit (`PathGate`). It compares nothing and knows no doc or board: it gives
//! each call its answer, or `Out` when the call did not return in time.

use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::watch;

use crate::boards::FileStamp;
use crate::docs::RepoInfo;

/// How long a caller waits for a call of the gate, and a look for its files in
/// each of its two steps (`PathGate`).
pub const READ_LIMIT: Duration = Duration::from_secs(1);

/// The call did not return within the limit, or an earlier call on its key is
/// still out.
#[derive(Debug)]
pub struct Out;

/// `None` for a file that is not there or cannot be read.
pub fn stamp(path: &Path) -> Option<FileStamp> {
    stamp_of(&std::fs::metadata(path).ok()?).ok()
}

fn stamp_of(meta: &std::fs::Metadata) -> std::io::Result<FileStamp> {
    Ok(FileStamp { mtime: meta.modified()?, len: meta.len(), inode: meta.ino() })
}

/// The file-system calls the gate makes.
pub trait PathFs: Send + Sync {
    /// canonicalize + stat. Err for a missing path, an I/O error, or a path
    /// that is not a regular file; the message is the one an open answers.
    fn resolve(&self, raw: &Path) -> Result<(PathBuf, FileStamp), String>;
    fn stamp(&self, path: &Path) -> Option<FileStamp>;
    fn repo_of(&self, doc: &Path) -> Option<RepoInfo>;
}

pub struct RealFs;

impl PathFs for RealFs {
    fn resolve(&self, raw: &Path) -> Result<(PathBuf, FileStamp), String> {
        // FSEvents reports resolved paths and the registry key must match them
        // (e.g. /tmp -> /private/tmp).
        let canon = std::fs::canonicalize(raw).map_err(|e| format!("cannot open {}: {e}", raw.display()))?;
        let cannot_stat = |e: std::io::Error| format!("cannot stat {}: {e}", canon.display());
        let meta = std::fs::metadata(&canon).map_err(cannot_stat)?;
        if !meta.is_file() {
            return Err(format!("not a regular file: {}", canon.display()));
        }
        let stamp = stamp_of(&meta).map_err(cannot_stat)?;
        Ok((canon, stamp))
    }

    fn stamp(&self, path: &Path) -> Option<FileStamp> {
        stamp(path)
    }

    fn repo_of(&self, doc: &Path) -> Option<RepoInfo> {
        crate::docs::derive_repo(doc)
    }
}

/// Runs each call on a blocking thread, and its caller waits at most `limit`.
/// A key has one call at a time: a `run` that finds its key busy waits for
/// that call within its own limit, then makes its own; a look gives a busy key
/// no entry. A call cannot be stopped, so a key whose caller stopped waiting
/// is out (a volume that is gone): a caller that comes after that gets `Out`
/// at once until the call returns, and one that was waiting already waits to
/// its own limit. A dead path holds one thread, however many callers ask for
/// it. When an out call returns, the gate calls `returned`.
///
/// An open's resolve is keyed by the path as given, a look's stamp by the
/// canonical one: a doc opened through a symlink can hold two calls.
pub struct PathGate {
    fs: Arc<dyn PathFs>,
    limit: Duration,
    keys: Arc<Keys>,
}

/// The keys whose call has not returned.
struct Keys {
    busy: Mutex<HashMap<PathBuf, Busy>>,
    next_call: AtomicU64,
    returned: Arc<dyn Fn() + Send + Sync>,
}

struct Busy {
    call: u64,
    out: bool,
    /// Dropped when the call returns, which wakes the callers waiting for it.
    ended: watch::Sender<()>,
}

enum Start {
    Flight(Flight),
    Wait(watch::Receiver<()>),
    Out,
}

/// One call on a key. Its drop, also in a panic, ends the call.
struct Flight {
    keys: Arc<Keys>,
    key: PathBuf,
    call: u64,
}

impl Keys {
    fn start(self: &Arc<Self>, key: &Path) -> Start {
        let mut busy = self.busy.lock().expect("keys lock");
        match busy.get(key) {
            Some(b) if b.out => Start::Out,
            // Subscribed under the lock: an end after it is not missed.
            Some(b) => Start::Wait(b.ended.subscribe()),
            None => {
                let call = self.next_call.fetch_add(1, Ordering::Relaxed);
                busy.insert(key.to_owned(), Busy { call, out: false, ended: watch::channel(()).0 });
                Start::Flight(Flight { keys: self.clone(), key: key.to_owned(), call })
            }
        }
    }

    /// Marks `call` out. False when it has returned already.
    fn leave(&self, key: &Path, call: u64) -> bool {
        match self.busy.lock().expect("keys lock").get_mut(key) {
            Some(b) if b.call == call => {
                b.out = true;
                true
            }
            _ => false,
        }
    }
}

impl Drop for Flight {
    fn drop(&mut self) {
        let ended = {
            let mut busy = self.keys.busy.lock().expect("keys lock");
            match busy.get(&self.key) {
                Some(b) if b.call == self.call => busy.remove(&self.key),
                _ => None,
            }
        };
        if ended.is_some_and(|b| b.out) {
            (self.keys.returned)();
        }
    }
}

/// What the thread of a look has done, in the order of its paths: the first
/// `done` are read or skipped, and `reading` is the call on `paths[done]`
/// while it is read.
#[derive(Default)]
struct Run {
    read: Vec<(PathBuf, Option<FileStamp>)>,
    done: usize,
    reading: Option<u64>,
    left: bool,
}

impl PathGate {
    pub fn new(fs: Arc<dyn PathFs>, limit: Duration, returned: Arc<dyn Fn() + Send + Sync>) -> Self {
        let keys = Keys { busy: Mutex::default(), next_call: AtomicU64::new(0), returned };
        PathGate { fs, limit, keys: Arc::new(keys) }
    }

    /// The answer to a caller of `what` that got `Out`.
    pub fn did_not_answer(&self, what: &str) -> String {
        format!("{what}: did not answer in {:?}", self.limit)
    }

    /// `op` on a blocking thread, keyed by `key`.
    pub async fn run<T: Send + 'static>(
        &self,
        key: &Path,
        op: impl FnOnce(&dyn PathFs) -> T + Send + 'static,
    ) -> Result<T, Out> {
        let deadline = tokio::time::Instant::now() + self.limit;
        let flight = loop {
            match self.keys.start(key) {
                Start::Flight(flight) => break flight,
                Start::Out => return Err(Out),
                Start::Wait(mut ended) => {
                    if tokio::time::timeout_at(deadline, ended.changed()).await.is_err() {
                        return Err(Out);
                    }
                }
            }
        };
        let call = flight.call;
        let mut task = tokio::task::spawn_blocking({
            let fs = self.fs.clone();
            move || {
                let _flight = flight;
                op(&*fs)
            }
        });
        match tokio::time::timeout_at(deadline, &mut task).await {
            Ok(joined) => Ok(joined.expect("a gate call does not panic")),
            Err(_) if self.keys.leave(key, call) => Err(Out),
            // It returned as the limit came: its answer is there.
            Err(_) => Ok(task.await.expect("a gate call does not panic")),
        }
    }

    /// True while an out key is `dir` or a file in it.
    #[cfg_attr(not(test), expect(dead_code, reason = "for the watcher thread of #267"))]
    pub fn is_out_dir(&self, dir: &Path) -> bool {
        let busy = self.keys.busy.lock().expect("keys lock");
        busy.iter().any(|(key, b)| b.out && (key == dir || key.parent() == Some(dir)))
    }

    /// Each file as it is now, for a look: on one blocking thread, one after
    /// the other, since one thread each would cost a 300-doc switch five times
    /// as much. When they are not read within `limit`, the read that is out is
    /// left on its thread, and the files after it are read on a thread each,
    /// within one more `limit`. A path whose key is busy has no entry: it is
    /// not known, which is not `None` (gone).
    pub async fn stamps(&self, paths: impl IntoIterator<Item = PathBuf>) -> HashMap<PathBuf, Option<FileStamp>> {
        let paths: Arc<[PathBuf]> = paths.into_iter().collect();
        let run = Arc::new(Mutex::new(Run::default()));
        let reading = tokio::task::spawn_blocking({
            let (fs, keys, run, paths) = (self.fs.clone(), self.keys.clone(), run.clone(), paths.clone());
            move || read_each(&*fs, &keys, &run, &paths)
        });
        let finished = tokio::time::timeout(self.limit, reading).await.is_ok();
        let (rest, mut now) = {
            let mut run = run.lock().expect("run lock");
            let rest = if finished {
                paths.len()
            } else {
                run.left = true;
                match run.reading {
                    // Its thread ends the call only under this lock, so the
                    // call is still there to leave.
                    Some(call) => {
                        self.keys.leave(&paths[run.done], call);
                        run.done + 1
                    }
                    None => run.done,
                }
            };
            (rest, run.read.drain(..).collect::<HashMap<_, _>>())
        };
        if rest < paths.len() {
            now.extend(self.read_apart(&paths[rest..]).await);
        }
        now
    }

    /// `paths`, each on a thread of its own, within one `limit`.
    async fn read_apart(&self, paths: &[PathBuf]) -> Vec<(PathBuf, Option<FileStamp>)> {
        let mut reads: Vec<_> = paths
            .iter()
            .filter_map(|path| {
                let Start::Flight(flight) = self.keys.start(path) else { return None };
                let (fs, call) = (self.fs.clone(), flight.call);
                let read = tokio::task::spawn_blocking(move || fs.stamp(&flight.key));
                Some((path.clone(), call, read))
            })
            .collect();
        let mut now = Vec::new();
        let mut next = 0;
        let _ = tokio::time::timeout(self.limit, async {
            while next < reads.len() {
                if let Ok(stamp) = (&mut reads[next].2).await {
                    now.push((reads[next].0.clone(), stamp));
                }
                next += 1;
            }
        })
        .await;
        // A call that cannot be left has ended, and its answer is about to be
        // in its handle. A handle that is dropped leaves its thread to finish.
        for (path, call, read) in reads.into_iter().skip(next) {
            if read.is_finished() || !self.keys.leave(&path, call) {
                now.extend(read.await.map(|stamp| (path, stamp)));
            }
        }
        now
    }
}

fn read_each(fs: &dyn PathFs, keys: &Arc<Keys>, run: &Mutex<Run>, paths: &[PathBuf]) {
    for (at, path) in paths.iter().enumerate() {
        let _flight = {
            let mut run = run.lock().expect("run lock");
            if run.left {
                return;
            }
            let Start::Flight(flight) = keys.start(path) else {
                run.done = at + 1;
                continue;
            };
            run.reading = Some(flight.call);
            flight
        };
        let stamp = fs.stamp(path);
        // The call ends (`_flight` is dropped) after this lock, never between a
        // caller that left and its look: the reading is pushed, or the call
        // is out when it ends and runs `returned`.
        let mut run = run.lock().expect("run lock");
        run.reading = None;
        run.done = at + 1;
        if run.left {
            return;
        }
        run.read.push((path.clone(), stamp));
    }
}
