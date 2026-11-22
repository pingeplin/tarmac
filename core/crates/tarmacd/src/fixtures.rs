use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use crate::boards::FileStamp;
use crate::proc::{Facts, Pid};
use crate::reader::{PathFs, RealFs};

// Per-test unique temp dir (process id + counter avoids collisions across
// parallel test threads or reused PIDs).
pub(crate) fn tmp_dir(tag: &str) -> PathBuf {
    static N: AtomicU32 = AtomicU32::new(0);
    let n = N.fetch_add(1, Ordering::Relaxed);
    let d = std::env::temp_dir().join(format!("tarmac-state-{}-{}-{n}", std::process::id(), tag));
    std::fs::create_dir_all(&d).unwrap();
    d
}

pub(crate) fn write_doc(path: PathBuf) -> PathBuf {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "doc").unwrap();
    path
}

pub(crate) const LIMIT: Duration = Duration::from_millis(200);

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub(crate) enum Call {
    Resolve,
    ResolveDir,
    Stamp,
    RepoOf,
    IsDir,
    PidCwd,
}

/// `RealFs`, whose calls that the test holds do not return until the
/// sender of `until_released` is dropped: a volume that is gone. It counts
/// every call of each method, and those it held. A `repo_of` that the
/// test names answers the repo the test names.
pub(crate) struct StuckFs {
    holds: std::sync::Mutex<Vec<(Call, PathBuf)>>,
    until_released: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
    /// Each method's calls on each path, and how many of them it held.
    counts: std::sync::Mutex<HashMap<(Call, PathBuf), (u32, u32)>>,
    repos: std::sync::Mutex<Vec<(PathBuf, String)>>,
    panics: std::sync::Mutex<Vec<PathBuf>>,
    /// The `pid_cwd` answers the test names, by pid, `None` for every pid.
    cwds: std::sync::Mutex<Vec<(Option<Pid>, Option<String>)>>,
    cwds_returned: AtomicU32,
    /// Calls that answer, as `RealFs` does, only after a delay.
    slows: std::sync::Mutex<Vec<(Call, PathBuf, Duration)>>,
}

impl StuckFs {
    /// Each later `call` on a path under `under` answers after `delay`: a
    /// slow volume that does answer.
    pub(crate) fn slow(&self, call: Call, under: &Path, delay: Duration) {
        self.slows.lock().unwrap().push((call, under.to_owned(), delay));
    }

    /// Each later `repo_of` of a doc in `dir` answers a repo `name` at
    /// `dir`, with no `.git` on disk.
    pub(crate) fn answer_repo(&self, dir: &Path, name: &str) {
        self.repos.lock().unwrap().push((dir.to_owned(), name.to_owned()));
    }

    /// Holds each later `call` on a path under `under`. A `pid_cwd` is
    /// held for every pid under `""`.
    pub(crate) fn hold(&self, call: Call, under: &Path) {
        self.holds.lock().unwrap().push((call, under.to_owned()));
    }

    /// Holds each later `pid_cwd` of `pid`.
    pub(crate) fn hold_pid(&self, pid: Pid) {
        self.hold(Call::PidCwd, &pid_path(pid));
    }

    /// Each later `pid_cwd` of `pid`, or of every pid for `None`, answers
    /// `cwd`. An answer for one pid comes before an answer for every pid.
    pub(crate) fn answer_cwd(&self, pid: Option<Pid>, cwd: Option<&str>) {
        self.cwds.lock().unwrap().push((pid, cwd.map(str::to_owned)));
    }

    /// The `pid_cwd` calls of `pid`.
    pub(crate) fn pid_cwd_calls(&self, pid: Pid) -> u32 {
        self.counts.lock().unwrap().get(&(Call::PidCwd, pid_path(pid))).map_or(0, |count| count.0)
    }

    /// The `pid_cwd` calls that returned.
    pub(crate) fn cwds_returned(&self) -> u32 {
        self.cwds_returned.load(Ordering::SeqCst)
    }

    /// Each later `stamp` of `path` panics.
    pub(crate) fn panic_on(&self, path: &Path) {
        self.panics.lock().unwrap().push(path.to_owned());
    }

    fn wait_if_held(&self, call: Call, path: &Path) {
        let held = self.holds.lock().unwrap().iter().any(|(c, under)| *c == call && path.starts_with(under));
        let mut counts = self.counts.lock().unwrap();
        let count = counts.entry((call, path.to_owned())).or_default();
        count.0 += 1;
        count.1 += u32::from(held);
        drop(counts);
        let slow =
            self.slows.lock().unwrap().iter().find(|(c, under, _)| *c == call && path.starts_with(under)).map(|s| s.2);
        if let Some(delay) = slow {
            std::thread::sleep(delay);
        }
        if held {
            let _ = self.until_released.lock().unwrap().recv();
        }
    }

    pub(crate) fn calls(&self, call: Call) -> u32 {
        self.counted(call).map(|count| count.0).sum()
    }

    pub(crate) fn held(&self, call: Call) -> u32 {
        self.counted(call).map(|count| count.1).sum()
    }

    fn counted(&self, call: Call) -> impl Iterator<Item = (u32, u32)> {
        let counts = self.counts.lock().unwrap();
        counts.iter().filter(|((c, _), _)| *c == call).map(|(_, count)| *count).collect::<Vec<_>>().into_iter()
    }
}

impl PathFs for StuckFs {
    fn resolve(&self, raw: &Path) -> Result<(PathBuf, FileStamp), String> {
        self.wait_if_held(Call::Resolve, raw);
        RealFs.resolve(raw)
    }

    fn resolve_dir(&self, raw: &Path) -> Option<PathBuf> {
        self.wait_if_held(Call::ResolveDir, raw);
        RealFs.resolve_dir(raw)
    }

    fn stamp(&self, path: &Path) -> Option<FileStamp> {
        self.wait_if_held(Call::Stamp, path);
        if self.panics.lock().unwrap().iter().any(|p| p == path) {
            panic!("the stamp of {} panics", path.display());
        }
        RealFs.stamp(path)
    }

    fn repo_of(&self, doc: &Path) -> Option<crate::docs::RepoInfo> {
        self.wait_if_held(Call::RepoOf, doc);
        let answer = self.repos.lock().unwrap().iter().find(|(dir, _)| doc.parent() == Some(dir)).cloned();
        let Some((dir, name)) = answer else { return RealFs.repo_of(doc) };
        let color = tarmac_protocol::repo_color_index(&name);
        Some(crate::docs::RepoInfo { name, root: dir.to_string_lossy().into_owned(), color })
    }
    fn is_dir(&self, path: &Path) -> bool {
        self.wait_if_held(Call::IsDir, path);
        RealFs.is_dir(path)
    }

    fn pid_cwd(&self, pid: libc::pid_t) -> Option<String> {
        self.wait_if_held(Call::PidCwd, &pid_path(pid));
        let answers = self.cwds.lock().unwrap().clone();
        let named = answers.iter().find(|(p, _)| *p == Some(pid)).or_else(|| answers.iter().find(|(p, _)| p.is_none()));
        let cwd = named.map_or_else(|| RealFs.pid_cwd(pid), |(_, cwd)| cwd.clone());
        self.cwds_returned.fetch_add(1, Ordering::SeqCst);
        cwd
    }
}

/// The path a hold of `pid_cwd` matches.
fn pid_path(pid: Pid) -> PathBuf {
    PathBuf::from(pid.to_string())
}

/// The test holds the sender to its end, a panic included: a runtime
/// waits for its blocking threads when it is dropped.
pub(crate) fn stuck_fs() -> (Arc<StuckFs>, std::sync::mpsc::Sender<()>) {
    let (release, until_released) = std::sync::mpsc::channel();
    let fs = Arc::new(StuckFs {
        holds: std::sync::Mutex::default(),
        until_released: std::sync::Mutex::new(until_released),
        counts: std::sync::Mutex::default(),
        repos: std::sync::Mutex::default(),
        panics: std::sync::Mutex::default(),
        cwds: std::sync::Mutex::default(),
        cwds_returned: AtomicU32::new(0),
        slows: std::sync::Mutex::default(),
    });
    (fs, release)
}

/// Runs `look` on a task of its own: a read that blocks the test's task
/// would block the timer that ends the wait too.
pub(crate) async fn answers<T: Send + 'static>(look: impl Future<Output = T> + Send + 'static) -> T {
    within(tokio::spawn(look)).await
}

pub(crate) async fn within<T>(task: tokio::task::JoinHandle<T>) -> T {
    tokio::time::timeout(Duration::from_secs(2), task).await.expect("an answer").unwrap()
}

pub(crate) const S: Pid = 100;
pub(crate) const L: Pid = 700;

pub(crate) fn facts(pairs: &[(Pid, Facts)]) -> impl Fn(Pid) -> Facts + use<> {
    let pairs = pairs.to_vec();
    move |pid| pairs.iter().find(|(p, _)| *p == pid).map_or(Facts::Gone, |(_, f)| *f)
}

pub(crate) fn live(started: u64) -> Facts {
    Facts::Live { ppid: 1, started }
}
