use std::sync::Arc;
use std::time::Duration;

use tarmac_protocol::TermInfo;

use crate::boards::BoardId;
use crate::proc;
use crate::term::{SpawnPlan, TermHandle};

use super::Daemon;

/// How long the shutdown save waits for the cwd reads of the live
/// terminals, all of them together. It is well inside the app's 2 s wait
/// for a daemon that it replaces.
pub(super) const SHUTDOWN_CWD_BUDGET: Duration = Duration::from_millis(500);

impl Daemon {
    /// Files a new terminal under `board` with its record: the record of
    /// `succeeds` when that board has one and the term is not live, else an
    /// empty one. Runs before the terminal's first cwd read, which only ever
    /// fills a record that is there.
    ///
    /// A moved resume command has no holder: `handle` is marked unclaimed in
    /// the same step, so typed input drops it (spec 2611.0011, D6).
    pub async fn adopt_term(&self, plan: &SpawnPlan, handle: &TermHandle) {
        let succeeds = match plan.succeeds.as_deref() {
            Some(old) if !self.terms.lock().await.contains_key(old) => Some(old),
            _ => None,
        };
        self.term_boards.lock().await.insert(plan.term_id.clone(), plan.board.clone());
        let mut boards = self.boards.lock().await;
        let Some(reg) = boards.known_registry_mut(&plan.board) else { return };
        let moved = succeeds.and_then(|old| reg.term_records.remove(old));
        if moved.is_some() {
            self.mark_dirty();
        }
        if moved.as_ref().is_some_and(|r| r.resume.is_some()) {
            handle.unclaim_resume();
        }
        reg.term_records.insert(plan.term_id.clone(), moved.unwrap_or_default());
    }

    /// Reads the cwd of `pid` on the gate and stores it in the record of
    /// `term_id`, on the board the term is filed under. A record that is gone
    /// (closed, ended cleanly, or its board deleted) is not made again, and a
    /// read with no answer keeps the cwd before it. Not saved by itself.
    pub async fn note_cwd(&self, term_id: &str, pid: proc::Pid) {
        let Ok(Some(cwd)) = self.gate.pid_cwd(pid).await else { return };
        let Some(board) = self.term_boards.lock().await.get(term_id).cloned() else { return };
        let mut boards = self.boards.lock().await;
        if let Some(record) = boards.known_registry_mut(&board).and_then(|reg| reg.term_records.get_mut(term_id)) {
            record.last_cwd = Some(cwd);
        }
    }

    /// Typed input: marks the report read, then drops a resume command that
    /// has no holder.
    pub async fn typed_input(&self, term_id: &str, handle: &TermHandle) {
        self.mark_report_read(term_id, handle).await;
        self.claim_resume(term_id, handle).await;
    }

    /// Reads the cwd of every live terminal at once, and records each that
    /// answers within `SHUTDOWN_CWD_BUDGET`. A read that does not keeps the cwd
    /// recorded before.
    pub async fn read_cwds(self: &Arc<Self>) {
        let deadline = tokio::time::Instant::now() + SHUTDOWN_CWD_BUDGET;
        let mut reads = tokio::task::JoinSet::new();
        for (term_id, pid) in self.foreground_pids().await {
            let daemon = self.clone();
            reads.spawn(async move {
                let _ = tokio::time::timeout_at(deadline, daemon.note_cwd(&term_id, pid)).await;
            });
        }
        while reads.join_next().await.is_some() {}
    }

    /// The foreground pid of each live terminal.
    async fn foreground_pids(&self) -> Vec<(String, proc::Pid)> {
        let terms = self.terms.lock().await;
        terms.iter().filter_map(|(id, h)| Some((id.clone(), h.foreground_pid()?))).collect()
    }

    /// Deletes the record of `term_id` from whichever board holds it, and
    /// marks the state dirty when there was one.
    async fn forget_record(&self, term_id: &str) {
        if self.boards.lock().await.forget_term(term_id) {
            self.mark_dirty();
        }
    }

    /// Deletes the record of `term_id`, live or not, and kills its process
    /// group when it is live.
    pub async fn close_term(&self, term_id: &str) {
        self.forget_record(term_id).await;
        match self.term(term_id).await {
            Some(h) => h.kill(),
            None => tracing::debug!("term_close for unknown term {term_id}"),
        }
    }

    /// Takes an exited terminal out of the maps. A clean exit (`Some(0)`)
    /// deletes its record; any other keeps it for the dead card.
    /// A terminal's end also ends its resume command, which a kept record
    /// keeps only once the shutdown has begun (spec 2611.0011, D3, D4).
    /// Returns the board the terminal was filed under, read as its entry goes:
    /// after this the daemon no longer knows it (spec 2611.0013).
    /// The exit is recorded first (spec 2611.0012, D4): a subscriber then
    /// finds the id live or in the ring, never neither.
    pub async fn term_ended(&self, term_id: &str, code: Option<i64>) -> Option<BoardId> {
        self.exits.lock().expect("exits lock").record(term_id, code);
        if self.terms.lock().await.remove(term_id).is_none() {
            tracing::warn!("term {term_id} missing from registry at exit");
        }
        let board_id = self.term_boards.lock().await.remove(term_id);
        // After the term left `terms`: a report or a resume command stored
        // after this is undone by its handler's own re-check.
        self.reports.lock().await.forget(term_id);
        if code == Some(0) {
            self.forget_record(term_id).await;
        } else {
            self.end_resume(term_id).await;
        }
        board_id
    }

    /// The live terminals for `tarmac terms` (spec 2611.0012), in board
    /// order, then by id. Each one's process name and cwd are read at the same
    /// time, the cwd on the gate, so the list takes about one gate limit, not
    /// one for each terminal. No lock is held while they are read.
    pub async fn terms_list(&self) -> Vec<TermInfo> {
        let by_board = self.live_terms_by_board().await;
        let live: Vec<(String, BoardId, Arc<TermHandle>)> = {
            let terms = self.terms.lock().await;
            by_board
                .into_iter()
                .flat_map(|(board_id, ids)| ids.into_iter().map(move |term_id| (term_id, board_id.clone())))
                .filter_map(|(term_id, board_id)| Some((term_id.clone(), board_id, terms.get(&term_id)?.clone())))
                .collect()
        };
        let mut reads = tokio::task::JoinSet::new();
        for (term_id, board_id, handle) in live {
            let gate = self.gate.clone();
            reads.spawn(async move {
                let (pid, cwd) = handle.foreground_read(&gate).await.unzip();
                TermInfo { term_id, board_id, cwd: cwd.flatten(), proc: pid.and_then(proc::process_name) }
            });
        }
        let mut rows = Vec::new();
        while let Some(read) = reads.join_next().await {
            rows.extend(read.ok());
        }
        let order: Vec<BoardId> = self.boards.lock().await.iter().map(|b| b.id.clone()).collect();
        // Ids sort as text, so `t10` comes before `t2`.
        rows.sort_by_cached_key(|row| (order.iter().position(|b| *b == row.board_id).unwrap_or(usize::MAX), row.term_id.clone()));
        rows
    }
}
