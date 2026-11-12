use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use tarmac_protocol::{MAX_FRAME_LEN, Msg};
use tokio::task::JoinSet;
use tracing::debug;

use crate::boards::{Boards, DocInfo, FileStamp, Registry, epoch_ms};
use crate::reader::{Out, PathFs, PathGate};
use crate::state::Daemon;

pub struct RepoInfo {
    pub name: String,
    pub root: String,
    pub color: u8,
}

// Walk parents toward / looking for a .git entry; a plain file counts too
// (worktrees and submodules use a gitfile). None means not in a repo.
pub fn derive_repo(doc: &Path) -> Option<RepoInfo> {
    let mut dir = doc.parent();
    while let Some(d) = dir {
        if d.join(".git").exists() {
            let name = d.file_name()?.to_string_lossy().into_owned();
            return Some(RepoInfo {
                color: tarmac_protocol::repo_color_index(&name),
                root: d.to_string_lossy().into_owned(),
                name,
            });
        }
        dir = d.parent();
    }
    None
}


// Single code path for CLI ("cli") and app ("user") opens. `term_id` is the
// calling terminal card, None when unknown. The doc lands on `board_id`, else
// the board owning the calling term, else the active board.
pub async fn handle_open(
    daemon: &Arc<Daemon>,
    raw_path: &str,
    via: &str,
    term_id: Option<String>,
    board_id: Option<String>,
) -> Result<(), String> {
    let p = Path::new(raw_path);
    if !p.is_absolute() {
        return Err(format!("path is not absolute: {raw_path}"));
    }
    let gate = daemon.gate();
    let (canon, seen) = resolve(gate, raw_path).await?;
    // `None` resolves to the active board inside `registry_mut`.
    let target = match (board_id, &term_id) {
        (Some(id), _) => Some(id),
        (None, Some(t)) => daemon.term_boards.lock().await.get(t).cloned(),
        (None, None) => None,
    };
    // A doc already on the board keeps its repo (`upsert_doc`), so only a new
    // one is walked, with no lock held. A walk that is out gives no repo.
    let registered = daemon.boards.lock().await.registry_mut(target.as_deref()).docs.contains_key(&canon);
    let repo = if registered {
        None
    } else {
        let walk = {
            let canon = canon.clone();
            move |fs: &dyn PathFs| fs.repo_of(&canon)
        };
        gate.run(&canon, walk).await.ok().flatten()
    };
    let entry = daemon
        .open_doc(target.as_deref(), &canon, via, term_id, Some(seen), repo)
        .await
        .map_err(|e| e.to_string())?;
    debug!("doc opened via {via}: {}", canon.display());
    daemon.push(Msg::DocOpened(entry)).await;
    Ok(())
}

/// `push`: gives `data`, one JSON value, to the app for the open doc
/// `raw_path`, as one `doc_event` with the registry's path whatever boards
/// hold the doc. The JSON check comes first, as it costs no file-system call.
/// A path the registry does not have as given is resolved through the gate
/// once for each connection, which owns `resolved` (given -> resolved); a
/// resolve that fails is not kept. The registry is asked on every push, so a
/// doc closed since is refused.
pub async fn handle_push(
    daemon: &Daemon,
    resolved: &mut HashMap<PathBuf, PathBuf>,
    raw_path: &str,
    data: String,
) -> Result<(), String> {
    serde_json::from_str::<serde_json::Value>(&data).map_err(|e| format!("not one JSON value: {e}"))?;
    let given = Path::new(raw_path);
    if !given.is_absolute() {
        return Err(format!("path is not absolute: {raw_path}"));
    }
    let key = match open_key(daemon, given).await {
        Some(key) => key,
        None => {
            let path = match resolved.get(given) {
                Some(path) => path.clone(),
                None => {
                    let (path, _) = resolve(daemon.gate(), raw_path).await?;
                    resolved.insert(given.to_owned(), path.clone());
                    path
                }
            };
            open_key(daemon, &path).await.ok_or_else(|| format!("not an open doc: {raw_path}"))?
        }
    };
    let event = Msg::DocEvent { path: key.to_string_lossy().into_owned(), data };
    // A frame over the limit would end the app's connection when it is
    // written (`conn::app_session`), after this push had been acked.
    if !tarmac_protocol::encode(&event).is_ok_and(|p| p.len() <= MAX_FRAME_LEN as usize) {
        return Err("value is over the frame limit (16 MiB)".into());
    }
    if !daemon.push(event).await {
        return Err("no app is connected".into());
    }
    Ok(())
}

/// `raw_path` resolved through the gate, keyed by the path as given, with
/// the texts an open answers.
async fn resolve(gate: &PathGate, raw_path: &str) -> Result<(PathBuf, FileStamp), String> {
    let given = Path::new(raw_path);
    let resolve = {
        let given = given.to_owned();
        move |fs: &dyn PathFs| fs.resolve(&given)
    };
    gate.run(given, resolve).await.map_err(|Out| gate.did_not_answer(&format!("cannot open {raw_path}")))?
}

/// The registry's key for `path` on any board, as it is written: `Path`
/// equality also takes `/./`, `//` and a trailing `/`, and the app keys its
/// cards by the text.
async fn open_key(daemon: &Daemon, path: &Path) -> Option<PathBuf> {
    let boards = daemon.boards.lock().await;
    boards.iter().find_map(|board| board.registry.docs.get_key_value(path)).map(|(key, _)| key.clone())
}

/// Registers `path` in `reg`, or refreshes the doc already there. True when
/// the doc is new to `reg`; `seen` is then its file as it is now, and `repo`
/// its repo. A doc already there keeps its own.
pub fn upsert_doc(
    reg: &mut Registry,
    path: &Path,
    via: &str,
    term_id: Option<String>,
    seen: Option<FileStamp>,
    repo: Option<RepoInfo>,
) -> bool {
    match reg.docs.get_mut(path) {
        Some(info) => {
            info.via = via.to_owned();
            info.last_opened_ms = epoch_ms(SystemTime::now());
            // Only cli opens may clear read; a user re-open leaves it. The
            // dock slot never moves on re-open. A re-open carrying a term_id
            // updates the provenance owner; one without keeps the prior owner.
            if via == "cli" {
                info.read = false;
            }
            if term_id.is_some() {
                info.term_id = term_id;
            }
            false
        }
        None => {
            reg.docs.insert(
                path.to_owned(),
                DocInfo {
                    via: via.to_owned(),
                    read: via != "cli",
                    repo: repo.as_ref().map(|r| r.name.clone()),
                    repo_root: repo.as_ref().map(|r| r.root.clone()),
                    repo_color: repo.as_ref().map(|r| r.color),
                    last_changed_ms: None,
                    seen,
                    untold: false,
                    unread: false,
                    last_opened_ms: epoch_ms(SystemTime::now()),
                    term_id,
                    data: None,
                },
            );
            reg.dock.push(path.to_owned());
            true
        }
    }
}

/// The restored docs' files and repos, read on the gate all at once: one
/// stamp batch for every doc, and one `.git` walk per dir, keyed by the dir
/// and made from one of its docs (`derive_repo` starts at the doc's parent).
/// It waits at most two limits in all. A doc whose file is not read in time
/// stays unread, and a dir whose walk is out leaves its docs with no repo.
pub async fn read_restored(gate: &Arc<PathGate>, boards: &mut Boards) {
    let docs = boards.doc_paths();
    let dirs: HashMap<&Path, &Path> = docs.iter().filter_map(|doc| Some((doc.parent()?, doc.as_path()))).collect();
    let mut walks = JoinSet::new();
    for (dir, doc) in dirs {
        let (gate, dir, doc) = (gate.clone(), dir.to_owned(), doc.to_owned());
        walks.spawn(async move {
            let repo = gate.run(&dir, move |fs: &dyn PathFs| fs.repo_of(&doc)).await.ok().flatten();
            (dir, repo)
        });
    }
    let now = gate.stamps(docs.iter().cloned()).await;
    let repos: HashMap<PathBuf, Option<RepoInfo>> = walks.join_all().await.into_iter().collect();
    boards.take_first_readings(&now);
    for reg in boards.registries_mut() {
        for (path, info) in &mut reg.docs {
            let repo = path.parent().and_then(|dir| repos.get(dir)).and_then(Option::as_ref);
            info.repo = repo.map(|r| r.name.clone());
            info.repo_root = repo.map(|r| r.root.clone());
            info.repo_color = repo.map(|r| r.color);
        }
    }
}

/// One look for each wake, `BURST` after it (#258, docs/architecture.md).
pub async fn watch_loop(daemon: Arc<Daemon>) {
    loop {
        daemon.woken().await;
        tokio::time::sleep(crate::watch::BURST).await;
        report_changes(&daemon).await;
    }
}

/// What a look has for the app: the docs of `reg` whose file changed
/// (`Registry::take_changes`), then those whose last change reached no app,
/// then the data files that changed (`Registry::take_data_changes`), one
/// `file_event` for a path that is both. It asks for the save of what it
/// recorded: before any push, so a crash between the two never loses the
/// fact. A data file records nothing to save.
pub fn take_to_tell(
    daemon: &Daemon,
    reg: &mut Registry,
    now: &HashMap<PathBuf, Option<FileStamp>>,
) -> Vec<(PathBuf, u64)> {
    let mut tell = reg.take_changes(now);
    if !tell.is_empty() {
        daemon.mark_dirty();
    }
    tell.extend(reg.take_untold());
    for (path, mtime_ms) in reg.take_data_changes(now) {
        if !tell.iter().any(|(told, _)| *told == path) {
            tell.push((path, mtime_ms));
        }
    }
    tell
}

/// Compares each doc and each data file of the active board with its file,
/// and pushes a `file_event` for each that changed. A doc of another board is
/// compared when its board is sent (`conn::change_and_send_active_board`). An
/// unread doc of any board is read too, and its first reading taken with no
/// change: a change after its volume answers is then told at its switch.
pub async fn report_changes(daemon: &Daemon) {
    let (board, tell) = daemon
        .look(
            |boards| {
                let paths = boards.active_registry().watched_paths().chain(boards.unread_doc_paths());
                paths.cloned().collect::<HashSet<_>>()
            },
            |boards, now| {
                boards.take_first_readings(now);
                let tell = take_to_tell(daemon, boards.active_registry_mut(), now);
                (boards.active_id().to_string(), tell)
            },
        )
        .await;
    for (path, mtime_ms) in tell {
        push_file_event(daemon, &board, &path, mtime_ms).await;
    }
}

pub fn file_event(path: &Path, mtime_ms: u64) -> Msg {
    Msg::FileEvent { path: path.to_string_lossy().into_owned(), mtime_ms }
}

/// Pushes the `file_event`, and holds the doc when it reached no app. `board`
/// is the board the change was taken for, which need not be active any more.
pub async fn push_file_event(daemon: &Daemon, board: &str, path: &Path, mtime_ms: u64) {
    if !daemon.push(file_event(path, mtime_ms)).await {
        daemon.boards.lock().await.hold(board, path);
    }
}

/// `doc_refresh`: stat `path` and, if it is a doc on the ACTIVE board, record
/// the mtime and push `file_event`. Returns whether it pushed.
///
/// It pushes always, with the mtime changed or not ("did anything change" is
/// answered app-side by value); `report_changes` pushes only for a file that
/// differs from what was seen. The registry lookup is also the active-board
/// check, which is why an unknown path costs one lock and no push.
pub async fn stat_and_push(daemon: &Arc<Daemon>, path: &Path) -> bool {
    let recorded = daemon
        .look(
            |_| vec![path.to_owned()],
            |boards, now| {
                let mtime_ms = boards.active_registry_mut().refresh(path, now.get(path).copied().flatten())?;
                // Before the push, as in `take_to_tell`.
                daemon.mark_dirty();
                Some((boards.active_id().to_string(), mtime_ms))
            },
        )
        .await;
    let Some((board, mtime_ms)) = recorded else { return false };
    push_file_event(daemon, &board, path, mtime_ms).await;
    true
}

/// `doc_data`: the doc `doc` of board `board` reads the file `data`, or none.
/// When the board is active and the file is there, the file is taken as seen
/// and a `file_event` for it is pushed, the same file again included. A board
/// in the background reports it at its switch. It is not held when it
/// reaches no app: the app sends `doc_data` again when it connects.
///
/// False, with nothing recorded, for an unknown board (no fall-back to the
/// active one), an unknown doc on it, or a `data` that is not a file in the
/// doc's own directory.
pub async fn record_data(daemon: &Daemon, board: &str, doc: &Path, data: Option<PathBuf>) -> bool {
    if data.as_deref().is_some_and(|data| !beside(doc, data)) {
        return false;
    }
    let recorded = daemon
        .look(
            |_| data.clone(),
            |boards, now| {
                let active = boards.active_id() == board;
                let reg = boards.known_registry_mut(board)?;
                if !reg.set_data(doc, data.clone()) {
                    return None;
                }
                Some(data.as_ref().filter(|_| active).and_then(|data| reg.see_data(data, *now.get(data)?)))
            },
        )
        .await;
    let Some(told) = recorded else { return false };
    if let (Some(data), Some(mtime_ms)) = (&data, told) {
        daemon.push(file_event(data, mtime_ms)).await;
    }
    true
}

/// `data` names a file in the directory of `doc`, judged on the text: no
/// link is followed, and a `..` is not resolved. A doc's path is absolute, so
/// a relative `data` is refused too.
fn beside(doc: &Path, data: &Path) -> bool {
    data.file_name().is_some() && data.parent() == doc.parent()
}
