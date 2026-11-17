use tarmac_protocol::{Msg, REPORT_CLEAR, ReportKind};

use crate::proc::{self, Pid};
use crate::reports::{Place, Reports};
use crate::term::TermHandle;

use super::Daemon;

impl Daemon {
    /// The answer to a cli `report` (spec 2611.0009): `Err` is the `err` text.
    /// `peer` is the client's pid, read at accept.
    pub async fn report(&self, peer: Option<Pid>, term_id: &str, kind: &str, text: Option<String>) -> Result<(), String> {
        let handle = self.term(term_id).await.ok_or_else(|| format!("unknown terminal: {term_id}"))?;
        if kind == REPORT_CLEAR {
            self.change_report(term_id, &handle, |reports| reports.clear(term_id)).await;
            return Ok(());
        }
        let kind = ReportKind::named(kind).ok_or_else(|| format!("unknown report kind: {kind}"))?;
        // Any socket client can send a `report`, so the daemon caps it too.
        let text = text.map(|t| tarmac_protocol::cap_report_text(&t)).filter(|t| !t.is_empty());
        let holder = handle
            .resolve_holder(peer)
            .ok_or_else(|| format!("no process to tie the report to in {term_id}"))?;
        let proc_name = proc::process_name(holder.pid());
        let now_ms = crate::boards::epoch_ms(std::time::SystemTime::now());
        let place = self.place(term_id).await;
        self.change_report(term_id, &handle, |reports| {
            Some(reports.report(term_id, kind, text, now_ms, holder, proc_name, place))
        })
        .await;
        // A terminal that exited while this ran: `term_ended` took it out of
        // `terms` before its own `forget`, so one of the two finds the entry.
        if self.term(term_id).await.is_none() {
            self.reports.lock().await.forget(term_id);
        }
        Ok(())
    }

    /// Where `term_id` is now: its board, then that board's record of its cwd,
    /// each lock released before the next and before `reports` is taken.
    async fn place(&self, term_id: &str) -> Place {
        let board_id = self.term_boards.lock().await.get(term_id).cloned();
        let cwd = match &board_id {
            Some(board) => self
                .boards
                .lock()
                .await
                .known_registry_mut(board)
                .and_then(|reg| reg.term_records.get(term_id))
                .and_then(|record| record.last_cwd.clone()),
            None => None,
        };
        Place { board_id, cwd }
    }

    /// The poll's check: removes the report when its holder is gone. `leader`
    /// is the tick's foreground-leader read.
    pub async fn check_report(&self, term_id: &str, handle: &TermHandle, leader: Option<Pid>) {
        if handle.has_report() {
            self.change_report(term_id, handle, |reports| {
                reports.check(term_id, |holder| holder.alive(proc::proc_facts, leader))
            })
            .await;
        }
    }

    /// Typed input marks an unread report read.
    pub(super) async fn mark_report_read(&self, term_id: &str, handle: &TermHandle) {
        if handle.unread_report() {
            self.change_report(term_id, handle, |reports| reports.mark_read(term_id)).await;
        }
    }

    /// One change of the store, the handle's flag and its push, all under the
    /// `reports` lock, so one terminal's frames keep their order.
    async fn change_report(&self, term_id: &str, handle: &TermHandle, change: impl FnOnce(&mut Reports) -> Option<Msg>) {
        let mut reports = self.reports.lock().await;
        let msg = change(&mut reports);
        handle.set_report(reports.has(term_id), reports.unread(term_id));
        if let Some(msg) = msg {
            self.emit(msg).await;
        }
    }
}
