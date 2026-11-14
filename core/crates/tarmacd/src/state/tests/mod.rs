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
mod pushes;
mod data_dirs;
mod term_records;
mod reports;

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
    eventually_async(what, || std::future::ready(done())).await;
}

async fn eventually_async<F: Future<Output = bool>>(what: &str, done: impl Fn() -> F) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !done().await {
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
    fn count(&self, change: Change) -> usize {
        self.0.lock().unwrap().iter().filter(|(c, _)| *c == change).count()
    }

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

/// Records each call; each watch of its dir fails.
struct WatchFails(PathBuf, Arc<SourceCalls>);

impl WakeSource for WatchFails {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
        self.1.0.lock().unwrap().push((Change::Watch, dir.to_owned()));
        anyhow::ensure!(dir != self.0, "too many paths");
        Ok(())
    }

    fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()> {
        self.1.0.lock().unwrap().push((Change::Unwatch, dir.to_owned()));
        Ok(())
    }
}

/// A daemon whose watcher is `source`, with no app.
async fn on_source(state_path: PathBuf, source: impl WakeSource + 'static) -> Arc<Daemon> {
    Daemon::with_source(state_path, Box::new(source), Arc::new(Wake::default())).await
}

/// A daemon whose watcher is `source` and whose gate calls `fs`.
async fn held(tmp: &Path, source: Box<dyn WakeSource>, fs: Arc<StuckFs>) -> Arc<Daemon> {
    Daemon::with_fs(tmp.join("state.json"), source, Arc::new(Wake::default()), fs, LIMIT).await
}

/// A daemon on `StuckFs` that loads `state`, its app, and a dir in a temp dir
/// of its own, which is not under `$HOME`. The test keeps `release` until
/// it lets the held calls return.
struct Rig {
    tmp: PathBuf,
    dir: PathBuf,
    daemon: Arc<Daemon>,
    app: mpsc::Receiver<Msg>,
    fs: Arc<StuckFs>,
    release: Option<std::sync::mpsc::Sender<()>>,
}

impl Rig {
    /// Lets every held call return, and each later one.
    fn release(&mut self) {
        self.release = None;
    }

    async fn end(mut self) {
        self.release();
        let terms: Vec<_> = self.daemon.terms.lock().await.values().cloned().collect();
        for term in terms {
            term.kill();
        }
        let _ = std::fs::remove_dir_all(&self.tmp);
    }
}

async fn rig_with(tag: &str, state: Option<serde_json::Value>, limit: Duration) -> Rig {
    let tmp = canon_tmp(tag);
    let dir = tmp.join("d");
    std::fs::create_dir_all(&dir).unwrap();
    if let Some(state) = state {
        std::fs::write(tmp.join("state.json"), state.to_string()).unwrap();
    }
    let (fs, release) = stuck_fs();
    let daemon = Daemon::with_fs(tmp.join("state.json"), Box::new(Silent), Arc::new(Wake::default()), fs.clone(), limit).await;
    let app = connect_app(&daemon).await;
    Rig { tmp, dir, daemon, app, fs, release: Some(release) }
}

/// What a test's `SpawnTerm` names beside its id and argv.
#[derive(Default, Clone, Copy)]
struct SpawnOpts<'a> {
    board: Option<&'a str>,
    cwd: Option<&'a Path>,
    inherit_cwd_from: Option<&'a str>,
    succeeds: Option<&'a str>,
}

/// The step of a `SpawnTerm` of `argv`, on a task of its own, and how long
/// it took to return.
async fn spawn(daemon: &Arc<Daemon>, term_id: &str, argv: &[&str], opts: SpawnOpts<'_>) -> Duration {
    let (daemon, term_id) = (daemon.clone(), term_id.to_owned());
    let cmd = argv.iter().map(|a| a.to_string()).collect();
    let owned = |s: Option<&str>| s.map(str::to_owned);
    let (board, inherit_cwd_from, succeeds) = (owned(opts.board), owned(opts.inherit_cwd_from), owned(opts.succeeds));
    let cwd = opts.cwd.map(|c| c.to_string_lossy().into_owned());
    let started = std::time::Instant::now();
    within(tokio::spawn(async move {
        crate::conn::spawn_requested(&daemon, term_id, (80, 24), cwd, Some(cmd), board, inherit_cwd_from, succeeds).await
    }))
    .await;
    started.elapsed()
}

async fn pid_of(daemon: &Daemon, term_id: &str) -> libc::pid_t {
    daemon.term(term_id).await.expect("the term runs").foreground_pid().expect("a foreground pid")
}

/// What `term_id` printed until `until` is in it, or to its exit when
/// `until` is `None`. An `err` frame fails the test.
async fn printed(app: &mut mpsc::Receiver<Msg>, term_id: &str, until: Option<&str>) -> String {
    let mut out = Vec::new();
    let frames = async {
        loop {
            match app.recv().await.expect("the app is connected") {
                Msg::Output { term_id: t, bytes } if t == term_id => {
                    out.extend(bytes);
                    if until.is_some_and(|u| String::from_utf8_lossy(&out).contains(u)) {
                        return;
                    }
                }
                Msg::Exit { term_id: t, .. } if t == term_id => return,
                Msg::Err { msg } => panic!("an err frame: {msg}"),
                _ => {}
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), frames).await.expect("the term's frames");
    String::from_utf8_lossy(&out).trim().to_owned()
}
