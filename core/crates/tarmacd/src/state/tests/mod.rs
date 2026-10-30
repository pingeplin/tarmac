use super::*;
use crate::fixtures::*;
use std::sync::atomic::AtomicU32;
use std::time::{Duration, SystemTime};

mod counts;
mod looks;
mod stuck_reads;
mod opens;
mod watches;
mod restart;
mod spawn_cwd;

async fn open_doc(daemon: &Daemon, board: Option<&str>, doc: &Path) {
    daemon.open_doc(board, doc, "t", None, crate::reader::stamp(doc), None).await.unwrap();
}

async fn watched(daemon: &Daemon, dir: &Path) -> bool {
    tokio::time::timeout(Duration::from_secs(5), daemon.watcher.watched(dir)).await.expect("the watcher answers")
}

fn state_with_docs(docs: &[&Path]) -> String {
    let docs: Vec<_> = docs
        .iter()
        .map(|p| serde_json::json!({"path": p, "via": "cli", "read": false}))
        .collect();
    serde_json::json!({"boards": [{"board_id": "board-0", "docs": docs}]}).to_string()
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

async fn connect_app(daemon: &Daemon) -> mpsc::Receiver<Msg> {
    let (tx, rx) = mpsc::channel(16);
    daemon.install_app(tx, None).await;
    rx
}

async fn next_file_event(app: &mut mpsc::Receiver<Msg>) -> u64 {
    next_change(app).await.1
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

/// A daemon that its watcher never wakes, whose gate calls `fs`, with no
/// app.
async fn gated(tmp: &Path, fs: Arc<StuckFs>) -> Arc<Daemon> {
    held(tmp, Box::new(Silent), fs).await
}

/// `silent_daemon` with `gone/a.md` open on the active board, whose reads
/// get stuck once the test says so.
async fn stuck_daemon(
    tag: &str,
) -> (PathBuf, Arc<Daemon>, mpsc::Receiver<Msg>, Arc<StuckFs>, std::sync::mpsc::Sender<()>) {
    let tmp = tmp_dir(tag);
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, release) = stuck_fs();
    let daemon = gated(&tmp, fs.clone()).await;
    let app = connect_app(&daemon).await;
    open_doc(&daemon, None, &doc).await;
    (tmp, daemon, app, fs, release)
}

async fn look_at(daemon: &Arc<Daemon>) {
    let daemon = daemon.clone();
    answers(async move { crate::docs::report_changes(&daemon).await }).await;
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

async fn eventually(what: &str, done: impl Fn() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !done() {
        assert!(std::time::Instant::now() < deadline, "{what} never happened");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

async fn repo_of(daemon: &Daemon, doc: &Path) -> (Option<String>, Option<String>, Option<u8>) {
    let entry = daemon.boards.lock().await.active_registry().entry(doc).unwrap();
    (entry.repo, entry.repo_root, entry.repo_color)
}

fn spawn_open(daemon: &Arc<Daemon>, doc: &Path) -> tokio::task::JoinHandle<Result<(), String>> {
    let (daemon, doc) = (daemon.clone(), doc.to_str().unwrap().to_owned());
    tokio::spawn(async move { crate::docs::handle_open(&daemon, &doc, "cli", None, None).await })
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

/// A daemon whose watcher is `source`, with no app.
async fn on_source(state_path: PathBuf, source: impl WakeSource + 'static) -> Arc<Daemon> {
    Daemon::with_source(state_path, Box::new(source), Arc::new(Notify::new())).await
}

/// A daemon whose watcher is `source` and whose gate calls `fs`.
async fn held(tmp: &Path, source: Box<dyn WakeSource>, fs: Arc<StuckFs>) -> Arc<Daemon> {
    Daemon::with_fs(tmp.join("state.json"), source, Arc::new(Notify::new()), fs, LIMIT).await
}
