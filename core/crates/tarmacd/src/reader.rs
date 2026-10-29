//! Every file-system call on a doc's path, on blocking threads, with a time
//! limit (`PathGate`). It compares nothing and knows no doc or board: it gives
//! each call its answer, or `Out` when the call did not return in time.

use std::collections::{HashMap, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
    let meta = std::fs::metadata(path).ok()?;
    Some(FileStamp { mtime: meta.modified().ok()?, len: meta.len(), inode: meta.ino() })
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
        let stamp = FileStamp { mtime: meta.modified().map_err(cannot_stat)?, len: meta.len(), inode: meta.ino() };
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
/// A call cannot be stopped, so a key whose call is out (a volume that is
/// gone) is not tried again until that call returns: it holds one thread, not
/// one for each caller. When it returns, the gate calls `returned`.
pub struct PathGate {
    fs: Arc<dyn PathFs>,
    limit: Duration,
    out: Arc<Mutex<HashSet<PathBuf>>>,
    returned: Arc<dyn Fn() + Send + Sync>,
}

/// What the thread of a look has read, in the order of its paths: the path it
/// reads now is the one after the last.
#[derive(Default)]
struct Run {
    read: Vec<(PathBuf, Option<FileStamp>)>,
    left: bool,
}

/// One call of `PathGate::run`, as its thread and its caller agree on it.
#[derive(PartialEq)]
enum Call {
    Running,
    Done,
    Left,
}

impl PathGate {
    pub fn new(fs: Arc<dyn PathFs>, limit: Duration, returned: Arc<dyn Fn() + Send + Sync>) -> Self {
        PathGate { fs, limit, out: Arc::default(), returned }
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
        if self.out.lock().expect("out lock").contains(key) {
            return Err(Out);
        }
        let call = Arc::new(Mutex::new(Call::Running));
        let mut task = tokio::task::spawn_blocking({
            let (fs, out, returned, call, key) =
                (self.fs.clone(), self.out.clone(), self.returned.clone(), call.clone(), key.to_owned());
            move || {
                let value = op(&*fs);
                let mut call = call.lock().expect("call lock");
                if *call == Call::Left {
                    out.lock().expect("out lock").remove(&key);
                    drop(call);
                    returned();
                } else {
                    *call = Call::Done;
                }
                value
            }
        });
        if let Ok(joined) = tokio::time::timeout(self.limit, &mut task).await {
            return Ok(joined.expect("a gate call does not panic"));
        }
        {
            // Under the call's lock, so that its thread finds the key in `out`
            // when it returns, or has returned already.
            let mut call = call.lock().expect("call lock");
            if *call == Call::Running {
                *call = Call::Left;
                self.out.lock().expect("out lock").insert(key.to_owned());
                return Err(Out);
            }
        }
        Ok(task.await.expect("a gate call does not panic"))
    }

    /// True while an out key is `dir` or a file in it.
    #[cfg_attr(not(test), expect(dead_code, reason = "for the watcher thread of #267"))]
    pub fn is_out_dir(&self, dir: &Path) -> bool {
        self.out.lock().expect("out lock").iter().any(|key| key == dir || key.parent() == Some(dir))
    }

    /// Each file as it is now, for a look: on one blocking thread, one after
    /// the other, since one thread each would cost a 300-doc switch five times
    /// as much. When they are not read within `limit`, the read that is out is
    /// left on its thread, and the files after it are read on a thread each,
    /// within one more `limit`. A path whose read is out has no entry: it is
    /// not known, which is not `None` (gone).
    pub async fn stamps(&self, paths: impl IntoIterator<Item = PathBuf>) -> HashMap<PathBuf, Option<FileStamp>> {
        let paths: Arc<[PathBuf]> = {
            let out = self.out.lock().expect("out lock");
            paths.into_iter().filter(|p| !out.contains(p)).collect()
        };
        let run = Arc::new(Mutex::new(Run::default()));
        let reading = tokio::task::spawn_blocking({
            let (fs, out, returned, run, paths) =
                (self.fs.clone(), self.out.clone(), self.returned.clone(), run.clone(), paths.clone());
            move || read_each(&*fs, &out, &*returned, &run, &paths)
        });
        let finished = tokio::time::timeout(self.limit, reading).await.is_ok();
        let (done, mut now) = {
            let mut run = run.lock().expect("run lock");
            let done = run.read.len();
            if !finished && done < paths.len() {
                run.left = true;
                self.out.lock().expect("out lock").insert(paths[done].clone());
            }
            (done, run.read.drain(..).collect::<HashMap<_, _>>())
        };
        if done < paths.len() {
            now.extend(self.read_apart(&paths[done + 1..]).await);
        }
        now
    }

    /// `paths`, each on a thread of its own, within one `limit`.
    async fn read_apart(&self, paths: &[PathBuf]) -> Vec<(PathBuf, Option<FileStamp>)> {
        let paths: Vec<PathBuf> = {
            let mut out = self.out.lock().expect("out lock");
            paths.iter().filter(|p| out.insert((*p).clone())).cloned().collect()
        };
        let left = Arc::new(Mutex::new(false));
        let reads: Vec<_> = paths
            .into_iter()
            .map(|path| {
                let (fs, out, returned, left) =
                    (self.fs.clone(), self.out.clone(), self.returned.clone(), left.clone());
                tokio::task::spawn_blocking(move || {
                    let stamp = fs.stamp(&path);
                    let left = left.lock().expect("left lock");
                    out.lock().expect("out lock").remove(&path);
                    if *left {
                        drop(left);
                        returned();
                    }
                    (path, stamp)
                })
            })
            .collect();
        let mut reads = reads.into_iter();
        let mut now = Vec::new();
        let _ = tokio::time::timeout(self.limit, async {
            for read in reads.by_ref() {
                now.extend(read.await);
            }
        })
        .await;
        *left.lock().expect("left lock") = true;
        // Taken in order, so a read that is out hides the ones after it that
        // are done. A handle that is dropped leaves its thread to finish.
        for read in reads.filter(|read| read.is_finished()) {
            now.extend(read.await);
        }
        now
    }
}

fn read_each(fs: &dyn PathFs, out: &Mutex<HashSet<PathBuf>>, returned: &(dyn Fn() + Send + Sync), run: &Mutex<Run>, paths: &[PathBuf]) {
    for path in paths {
        let stamp = fs.stamp(path);
        let mut run = run.lock().expect("run lock");
        if run.left {
            out.lock().expect("out lock").remove(path);
            drop(run);
            returned();
            return;
        }
        run.read.push((path.clone(), stamp));
    }
}
