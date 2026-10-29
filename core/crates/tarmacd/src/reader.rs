//! Every file-system call on a doc's path, on blocking threads, with a time
//! limit (`PathGate`). It compares nothing and knows no doc or board: it gives
//! each call its answer, or `Out` when the call did not return in time.

use std::collections::{HashMap, VecDeque};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::Instant;

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
    fn is_dir(&self, path: &Path) -> bool;
    fn pid_cwd(&self, pid: libc::pid_t) -> Option<String>;
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

    fn is_dir(&self, path: &Path) -> bool {
        path.is_dir()
    }

    fn pid_cwd(&self, pid: libc::pid_t) -> Option<String> {
        crate::proc::pid_cwd(pid)
    }
}

/// Runs each call on a blocking thread, and its caller waits at most `limit`.
/// A key has one call at a time: a `run` that finds its key busy waits for
/// that call within its own limit, then makes its own; a look gives a busy key
/// no entry. A call cannot be stopped, so a caller that stops waiting leaves
/// it on its thread, and the gate calls `returned` when it returns. A call
/// that is left is out once it has had a full limit: its caller's, or for a
/// caller that waited first, one from the call's start, since a slow call is
/// not a dead one (#280). A caller that comes to an out key gets `Out` at once
/// until the call returns, and one that was waiting already waits to its own
/// limit. A dead path holds one thread, however many callers ask for it.
///
/// An open's resolve is keyed by the path as given, a look's stamp by the
/// canonical one: a doc opened through a symlink can hold two calls. A
/// startup walk is keyed by its directory, a spawn's `is_dir` by its cwd, and
/// a `pid_cwd` by the pid.
pub struct PathGate {
    fs: Arc<dyn PathFs>,
    limit: Duration,
    keys: Arc<Keys>,
}

#[derive(Clone, PartialEq, Eq, Hash)]
enum Key {
    Path(PathBuf),
    Pid(libc::pid_t),
}

/// What a caller does when its key is busy.
#[derive(Clone, Copy)]
enum OnBusy {
    /// Waits for that call, then makes its own.
    Wait,
    /// Makes no call: the key is not known.
    Skip,
}

/// The keys whose call has not returned.
struct Keys {
    busy: Mutex<HashMap<Key, Busy>>,
    next_call: AtomicU64,
    returned: Arc<dyn Fn() + Send + Sync>,
}

struct Busy {
    call: u64,
    /// Its caller stopped waiting for it.
    left: bool,
    out_at: Instant,
    /// Dropped when the call returns, which wakes the callers waiting for it.
    ended: watch::Sender<()>,
}

impl Busy {
    fn is_out(&self, now: Instant) -> bool {
        self.left && now >= self.out_at
    }
}

enum Claim<T> {
    Flight(Takeoff<T>, Landing<T>),
    Wait(watch::Receiver<()>),
    Out,
}

/// One call on a key. Its drop, also in a panic, ends the call.
struct Flight {
    keys: Arc<Keys>,
    key: Key,
    call: u64,
}

/// The thread's end of a flight.
struct Takeoff<T> {
    flight: Flight,
    answer: oneshot::Sender<T>,
}

/// The caller's end of a flight.
struct Landing<T> {
    keys: Arc<Keys>,
    key: Key,
    call: u64,
    answer: oneshot::Receiver<T>,
}

impl Keys {
    /// A call on `key`, out at `out_at` once its caller leaves it. A busy key
    /// is `Wait` for a caller that waits, and `Out` for one that skips.
    fn claim<T>(self: &Arc<Self>, key: &Key, on_busy: OnBusy, out_at: Instant) -> Claim<T> {
        let mut busy = self.busy.lock().expect("keys lock");
        match busy.get(key) {
            // Subscribed under the lock: an end after it is not missed.
            Some(b) if matches!(on_busy, OnBusy::Wait) && !b.is_out(Instant::now()) => Claim::Wait(b.ended.subscribe()),
            Some(_) => Claim::Out,
            None => {
                let call = self.next_call.fetch_add(1, Ordering::Relaxed);
                busy.insert(key.clone(), Busy { call, left: false, out_at, ended: watch::channel(()).0 });
                let (sent, answer) = oneshot::channel();
                let flight = Flight { keys: self.clone(), key: key.clone(), call };
                Claim::Flight(
                    Takeoff { flight, answer: sent },
                    Landing { keys: self.clone(), key: key.clone(), call, answer },
                )
            }
        }
    }

    /// Leaves `call`. False when it has returned already.
    fn leave(&self, key: &Key, call: u64) -> bool {
        match self.busy.lock().expect("keys lock").get_mut(key) {
            Some(b) if b.call == call => {
                b.left = true;
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
        if ended.is_some_and(|b| b.left) {
            (self.keys.returned)();
        }
    }
}

impl<T> Takeoff<T> {
    /// `op` on this thread. The answer is sent before the call ends, so a
    /// caller that cannot leave the call finds it.
    fn fly(self, fs: &dyn PathFs, op: impl FnOnce(&dyn PathFs) -> T) {
        let _ = self.answer.send(op(fs));
        drop(self.flight);
    }
}

impl<T> Landing<T> {
    /// The answer, or `Out` when it is not there at `deadline`: the call is
    /// then left.
    async fn land(mut self, deadline: Instant) -> Result<T, Out> {
        if let Ok(answer) = tokio::time::timeout_at(deadline, &mut self.answer).await {
            return Ok(answer.expect("a gate call does not panic"));
        }
        if self.keys.leave(&self.key, self.call) {
            return Err(Out);
        }
        // It returned as the deadline came: its answer is there.
        Ok(self.answer.await.expect("a gate call does not panic"))
    }
}

impl PathGate {
    pub fn new(fs: Arc<dyn PathFs>, limit: Duration, returned: Arc<dyn Fn() + Send + Sync>) -> Self {
        let keys = Keys { busy: Mutex::default(), next_call: AtomicU64::new(0), returned };
        PathGate { fs, limit, keys: Arc::new(keys) }
    }

    pub fn limit(&self) -> Duration {
        self.limit
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
        self.run_keyed(Key::Path(key.to_owned()), op).await
    }

    /// The cwd of `pid`, one call per pid at a time.
    pub async fn pid_cwd(&self, pid: libc::pid_t) -> Result<Option<String>, Out> {
        self.run_keyed(Key::Pid(pid), move |fs| fs.pid_cwd(pid)).await
    }

    async fn run_keyed<T: Send + 'static>(
        &self,
        key: Key,
        op: impl FnOnce(&dyn PathFs) -> T + Send + 'static,
    ) -> Result<T, Out> {
        let deadline = Instant::now() + self.limit;
        let mut out_at = deadline;
        let (takeoff, landing) = loop {
            match self.keys.claim(&key, OnBusy::Wait, out_at) {
                Claim::Flight(takeoff, landing) => break (takeoff, landing),
                Claim::Out => return Err(Out),
                Claim::Wait(mut ended) => {
                    if tokio::time::timeout_at(deadline, ended.changed()).await.is_err() {
                        return Err(Out);
                    }
                    // Its own call has what is left of its limit: when it
                    // leaves that call sooner, the call is busy, not out.
                    out_at = Instant::now() + self.limit;
                }
            }
        };
        self.fly_apart(takeoff, op);
        landing.land(deadline).await
    }

    fn fly_apart<T: Send + 'static>(&self, takeoff: Takeoff<T>, op: impl FnOnce(&dyn PathFs) -> T + Send + 'static) {
        let fs = self.fs.clone();
        tokio::task::spawn_blocking(move || takeoff.fly(&*fs, op));
    }

    /// True while an out key is `dir` or a file in it.
    pub fn is_out_dir(&self, dir: &Path) -> bool {
        let (busy, now) = (self.keys.busy.lock().expect("keys lock"), Instant::now());
        busy.iter().any(|(key, b)| b.is_out(now) && matches!(key, Key::Path(p) if p == dir || p.parent() == Some(dir)))
    }

    /// Each file as it is now, for a look: on one blocking thread, one after
    /// the other, since one thread each would cost a 300-doc switch five times
    /// as much. When they are not read within `limit`, the read that is out is
    /// left on its thread, and the files after it are read on a thread each,
    /// within one more `limit`. A path whose key is busy has no entry: it is
    /// not known, which is not `None` (gone).
    pub async fn stamps(&self, paths: impl IntoIterator<Item = PathBuf>) -> HashMap<PathBuf, Option<FileStamp>> {
        let deadline = Instant::now() + self.limit;
        let rest = Arc::new(Mutex::new(paths.into_iter().collect::<VecDeque<_>>()));
        let (landed, mut landings) = mpsc::unbounded_channel();
        tokio::task::spawn_blocking({
            let (fs, keys, rest) = (self.fs.clone(), self.keys.clone(), rest.clone());
            move || read_each(&*fs, &keys, &rest, deadline, &landed)
        });
        let mut now = HashMap::new();
        while let Ok(Some((path, landing))) = tokio::time::timeout_at(deadline, landings.recv()).await {
            match landing.land(deadline).await {
                Ok(stamp) => now.insert(path, stamp),
                Err(Out) => break,
            };
        }
        let rest: Vec<_> = rest.lock().expect("rest lock").drain(..).collect();
        // The thread starts no call after the drain, and has sent the landing
        // of each call it started: one it started after the deadline is
        // landed with the rest.
        let mut started = Vec::new();
        while let Ok(landed) = landings.try_recv() {
            started.push(landed);
        }
        now.extend(self.read_apart(rest, started).await);
        now
    }

    /// `paths`, each on a thread of its own, and the calls `started`, within
    /// one `limit`.
    async fn read_apart(&self, paths: Vec<PathBuf>, started: Vec<Landed>) -> Vec<(PathBuf, Option<FileStamp>)> {
        let deadline = Instant::now() + self.limit;
        let mut landings = started;
        for path in paths {
            if let Claim::Flight(takeoff, landing) = self.keys.claim(&Key::Path(path.clone()), OnBusy::Skip, deadline) {
                let read = path.clone();
                self.fly_apart(takeoff, move |fs| fs.stamp(&read));
                landings.push((path, landing));
            }
        }
        let mut now = Vec::new();
        for (path, landing) in landings {
            if let Ok(stamp) = landing.land(deadline).await {
                now.push((path, stamp));
            }
        }
        now
    }
}

type Landed = (PathBuf, Landing<Option<FileStamp>>);

fn read_each(
    fs: &dyn PathFs,
    keys: &Arc<Keys>,
    rest: &Mutex<VecDeque<PathBuf>>,
    out_at: Instant,
    landed: &mpsc::UnboundedSender<Landed>,
) {
    loop {
        // Under the lock that `stamps` drains `rest` with: each path is in
        // `rest`, skipped, or its landing is sent.
        let (takeoff, path) = {
            let mut rest = rest.lock().expect("rest lock");
            let Some(path) = rest.pop_front() else { return };
            let Claim::Flight(takeoff, landing) = keys.claim(&Key::Path(path.clone()), OnBusy::Skip, out_at) else {
                continue;
            };
            let _ = landed.send((path.clone(), landing));
            (takeoff, path)
        };
        takeoff.fly(fs, |fs| fs.stamp(&path));
    }
}
