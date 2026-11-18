//! Spec 2611.0016: a cli's `term_new`, forwarded to the app, which mints the
//! terminal; the daemon spawns nothing by itself.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tarmac_protocol::{Msg, refuse_term_new_cmd};
use tokio::sync::oneshot;

use crate::boards::BoardId;

use super::Daemon;

/// How long the daemon waits for the app, inside the cli's own 5 s, so that
/// only a daemon that predates `term_new` leaves the cli unanswered (D10).
pub const TERM_NEW_APP_WAIT: Duration = Duration::from_secs(4);

pub const APP_WENT_AWAY: &str = "the app went away";

type Answer = Result<String, String>;

/// The requests forwarded to the app, by `req_id`. The lock is held for a map
/// update only.
#[derive(Default)]
pub struct TermNews {
    next: AtomicU64,
    waiting: std::sync::Mutex<HashMap<u64, Waiting>>,
}

struct Waiting {
    /// The app connection the request was pushed to.
    generation: u64,
    answer: oneshot::Sender<Answer>,
}

impl TermNews {
    pub(super) fn wait(&self, generation: u64) -> (u64, oneshot::Receiver<Answer>) {
        let req_id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let (answer, rx) = oneshot::channel();
        self.waiting.lock().expect("term news lock").insert(req_id, Waiting { generation, answer });
        (req_id, rx)
    }

    pub(super) fn take(&self, req_id: u64) -> Option<oneshot::Sender<Answer>> {
        self.waiting.lock().expect("term news lock").remove(&req_id).map(|w| w.answer)
    }

    /// Ends each request pushed to the connection `generation`.
    pub fn app_gone(&self, generation: u64) {
        let gone: Vec<Waiting> = {
            let mut waiting = self.waiting.lock().expect("term news lock");
            let ids: Vec<u64> = waiting.iter().filter(|(_, w)| w.generation == generation).map(|(id, _)| *id).collect();
            ids.iter().filter_map(|id| waiting.remove(id)).collect()
        };
        for w in gone {
            let _ = w.answer.send(Err(APP_WENT_AWAY.into()));
        }
    }
}

impl Daemon {
    /// The answer to a cli `term_new`: the new terminal's id, or the line the
    /// cli prints. One bound, `wait`, covers the whole request from its
    /// arrival: the folder's read, the push and the app's answer (D10).
    pub async fn term_new(&self, cmd: String, cwd: String, term_id: Option<String>, wait: Duration) -> Answer {
        let deadline = tokio::time::Instant::now() + wait;
        refuse_term_new_cmd(&cmd)?;
        let folder = tokio::time::timeout_at(deadline, self.term_new_folder(&cwd)).await;
        folder.unwrap_or_else(|_| Err(format!("not a directory: {cwd}")))?;
        let (term_id, board_id) = self.term_new_board(term_id).await;
        // Under the app lock: the request belongs to the connection it is
        // pushed to, which `install_app` and `remove_app` end with the lock held.
        let (req_id, rx, tx) = {
            let slot = self.app.lock().await;
            let Some(slot) = slot.as_ref() else { return Err("no app connected".into()) };
            let (req_id, rx) = self.term_news.wait(slot.generation);
            (req_id, rx, slot.tx.clone())
        };
        let msg = Msg::TermNew { req_id: Some(req_id), cmd, cwd, term_id, board_id: Some(board_id) };
        let answer = async {
            if tx.send(msg).await.is_err() {
                return Err("no app connected".to_string());
            }
            rx.await.unwrap_or_else(|_| Err(APP_WENT_AWAY.into()))
        };
        let answer = tokio::time::timeout_at(deadline, answer).await.unwrap_or_else(|_| Err("the app did not answer".into()));
        // A no-op after an answer, which took the request.
        self.term_news.take(req_id);
        answer
    }

    /// The app's answer to request `req_id`. An `Ok` names a terminal the
    /// daemon must hold, live or ended (D9): a spawn that failed told only
    /// the app. One with no request waiting is dropped.
    pub async fn term_new_answered(&self, req_id: u64, answer: Answer) {
        let Some(tx) = self.term_news.take(req_id) else {
            tracing::debug!("term_new answer {req_id} has no request waiting");
            return;
        };
        let answer = match answer {
            Ok(term_id) if !self.holds(&term_id).await => Err("the terminal did not start".to_string()),
            answer => answer,
        };
        let _ = tx.send(answer);
    }

    /// `terms` before the exit ring: an ending terminal is recorded in the
    /// ring before it leaves `terms`.
    async fn holds(&self, term_id: &str) -> bool {
        self.terms.lock().await.contains_key(term_id) || self.exits.lock().expect("exits lock").lookup(term_id).is_some()
    }

    /// D3: an absolute path that the gate reads as a directory.
    async fn term_new_folder(&self, cwd: &str) -> Result<(), String> {
        let path = PathBuf::from(cwd);
        if !path.is_absolute() {
            return Err(format!("not an absolute path: {cwd}"));
        }
        let probe = path.clone();
        match self.gate.run(&path, move |fs| fs.is_dir(&probe)).await {
            Ok(true) => Ok(()),
            _ => Err(format!("not a directory: {cwd}")),
        }
    }

    /// D4: a live caller and its board, else no caller and the active board.
    async fn term_new_board(&self, term_id: Option<String>) -> (Option<String>, BoardId) {
        let live = match &term_id {
            Some(id) if self.term(id).await.is_some() => self.term_boards.lock().await.get(id).cloned().map(|b| (id.clone(), b)),
            _ => None,
        };
        match live {
            Some((id, board)) => (Some(id), board),
            None => (None, self.boards.lock().await.active_id().to_string()),
        }
    }
}
