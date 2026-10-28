//! Reads the files of a look (`Daemon::look`) on blocking threads, with a time
//! limit. It compares nothing and knows no doc or board: it gives each path
//! its `FileStamp`, or no entry when the read did not return in time.

use std::collections::{HashMap, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::boards::FileStamp;

/// How long a look waits for its files, in each of its two steps
/// (`FileReader`).
pub const READ_LIMIT: Duration = Duration::from_secs(1);

/// `None` for a file that is not there or cannot be read.
pub fn stamp(path: &Path) -> Option<FileStamp> {
    let meta = std::fs::metadata(path).ok()?;
    Some(FileStamp { mtime: meta.modified().ok()?, len: meta.len(), inode: meta.ino() })
}

pub type ReadFile = dyn Fn(&Path) -> Option<FileStamp> + Send + Sync;

/// Reads the files of a look on one blocking thread, one after the other: one
/// thread each would cost a 300-doc switch five times as much. When they are
/// not read within `limit`, the read that is out (a volume that is gone) is
/// left on its thread, and the files after it are read on a thread each,
/// within one more `limit`. A stat cannot be stopped, so a path whose read is
/// out is not read again until it returns: it holds one thread, not one for
/// each look.
pub struct FileReader {
    read: Arc<ReadFile>,
    limit: Duration,
    out: Arc<Mutex<HashSet<PathBuf>>>,
}

impl Default for FileReader {
    fn default() -> Self {
        FileReader::new(Arc::new(stamp), READ_LIMIT)
    }
}

/// What the thread of a look has read, in the order of its paths: the path it
/// reads now is the one after the last.
#[derive(Default)]
struct Run {
    read: Vec<(PathBuf, Option<FileStamp>)>,
    left: bool,
}

impl FileReader {
    pub fn new(read: Arc<ReadFile>, limit: Duration) -> Self {
        FileReader { read, limit, out: Arc::default() }
    }

    /// Each file as it is now. A path whose read is out has no entry: it is
    /// not known, which is not `None` (gone).
    pub async fn stamps(&self, paths: impl IntoIterator<Item = PathBuf>) -> HashMap<PathBuf, Option<FileStamp>> {
        let paths: Arc<[PathBuf]> = {
            let out = self.out.lock().expect("out lock");
            paths.into_iter().filter(|p| !out.contains(p)).collect()
        };
        let run = Arc::new(Mutex::new(Run::default()));
        let reading = tokio::task::spawn_blocking({
            let (read, out, run, paths) = (self.read.clone(), self.out.clone(), run.clone(), paths.clone());
            move || read_each(&*read, &out, &run, &paths)
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
        let reads: Vec<_> = paths
            .into_iter()
            .map(|path| {
                let (read, out) = (self.read.clone(), self.out.clone());
                tokio::task::spawn_blocking(move || {
                    let stamp = read(&path);
                    out.lock().expect("out lock").remove(&path);
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
        // Taken in order, so a read that is out hides the ones after it that
        // are done. A handle that is dropped leaves its thread to finish.
        for read in reads.filter(|read| read.is_finished()) {
            now.extend(read.await);
        }
        now
    }
}

fn read_each(read: &ReadFile, out: &Mutex<HashSet<PathBuf>>, run: &Mutex<Run>, paths: &[PathBuf]) {
    for path in paths {
        let stamp = read(path);
        let mut run = run.lock().expect("run lock");
        if run.left {
            out.lock().expect("out lock").remove(path);
            return;
        }
        run.read.push((path.clone(), stamp));
    }
}
