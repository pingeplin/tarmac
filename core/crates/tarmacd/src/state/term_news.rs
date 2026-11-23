//! Spec 2611.0016: a cli's `term_new`, forwarded to the app, which mints the
//! terminal; the daemon spawns nothing by itself.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tarmac_protocol::{Msg, refuse_term_new_cmd};
use tokio::sync::oneshot;

use crate::boards::BoardId;

use super::Daemon;

/// How long the daemon waits for the app, inside the cli's own 5 s, so that
/// only a daemon that predates `term_new` leaves the cli unanswered (D10).
pub(crate) const TERM_NEW_APP_WAIT: Duration = Duration::from_secs(4);
const _: () = assert!(TERM_NEW_APP_WAIT.as_millis() < tarmac_protocol::DAEMON_WAIT.as_millis());

pub(super) const NO_APP: &str = "no app connected";
pub(super) const APP_WENT_AWAY: &str = "the app went away";
pub(super) const APP_DID_NOT_ANSWER: &str = "the app did not answer";
pub(super) const TERM_DID_NOT_START: &str = "the terminal did not start";

type Answer = Result<String, String>;

/// The requests forwarded to the app, by `req_id`. The lock is held for a map
/// update only.
#[derive(Default)]
pub(crate) struct TermNews {
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
    pub(crate) fn app_gone(&self, generation: u64) {
        let gone: Vec<Waiting> = self
            .waiting
            .lock()
            .expect("term news lock")
            .extract_if(|_, w| w.generation == generation)
            .map(|(_, w)| w)
            .collect();
        for w in gone {
            let _ = w.answer.send(Err(APP_WENT_AWAY.into()));
        }
    }
}

impl Daemon {
    /// The answer to a cli `term_new`: the new terminal's id, or the line the
    /// cli prints. One bound, `wait`, covers the whole request from its
    /// arrival: the folder's read, the push and the app's answer (D10).
    pub(crate) async fn term_new(&self, cmd: String, cwd: String, term_id: Option<String>, wait: Duration) -> Answer {
        let deadline = tokio::time::Instant::now() + wait;
        refuse_term_new_cmd(&cmd)?;
        // Before the folder's read, which can take the bound: no app, no wait.
        if self.app.lock().await.is_none() {
            return Err(NO_APP.into());
        }
        let folder = tokio::time::timeout_at(deadline, self.term_new_folder(&cwd)).await;
        folder.unwrap_or_else(|_| Err(format!("not a directory: {cwd}")))?;
        let (term_id, board_id) = self.term_new_board(term_id).await;
        // Under the app lock: the request belongs to the connection it is
        // pushed to, which `install_app` and `remove_app` end with the lock held.
        let (req_id, rx, tx) = {
            let slot = self.app.lock().await;
            let Some(slot) = slot.as_ref() else { return Err(NO_APP.into()) };
            let (req_id, rx) = self.term_news.wait(slot.generation);
            (req_id, rx, slot.tx.clone())
        };
        let msg = Msg::TermNew { req_id: Some(req_id), cmd, cwd, term_id, board_id: Some(board_id) };
        let answer = async {
            if tx.send(msg).await.is_err() {
                return Err(NO_APP.to_string());
            }
            rx.await.unwrap_or_else(|_| Err(APP_WENT_AWAY.into()))
        };
        let answer = tokio::time::timeout_at(deadline, answer).await.unwrap_or_else(|_| Err(APP_DID_NOT_ANSWER.into()));
        // A no-op after an answer, which took the request.
        self.term_news.take(req_id);
        answer
    }

    /// The app's answer to request `req_id`. An `Ok` names a terminal the
    /// daemon must hold, live or ended (D9): a spawn that failed told only
    /// the app. One with no request waiting is dropped.
    pub(crate) async fn term_new_answered(&self, req_id: u64, answer: Answer) {
        let Some(tx) = self.term_news.take(req_id) else {
            tracing::debug!("term_new answer {req_id} has no request waiting");
            return;
        };
        let answer = match answer {
            Ok(term_id) if self.knows_term(&term_id).await.is_none() => Err(TERM_DID_NOT_START.to_string()),
            answer => answer,
        };
        let _ = tx.send(answer);
    }

    /// D3: an absolute path that the gate reads as a directory.
    async fn term_new_folder(&self, cwd: &str) -> Result<(), String> {
        let path = Path::new(cwd);
        if !path.is_absolute() {
            return Err(format!("not an absolute path: {cwd}"));
        }
        if !self.is_dir(path).await {
            return Err(format!("not a directory: {cwd}"));
        }
        Ok(())
    }

    /// D4: a caller the daemon knows and its board, else no caller and the
    /// active board.
    async fn term_new_board(&self, term_id: Option<String>) -> (Option<String>, BoardId) {
        let board = self.caller_board(term_id.as_deref()).await;
        match (term_id, board) {
            (Some(id), Some(board)) => (Some(id), board),
            _ => (None, self.boards.lock().await.active_id().to_string()),
        }
    }
}
