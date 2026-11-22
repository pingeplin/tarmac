use std::sync::atomic::Ordering;

use tarmac_protocol::{Msg, ResumeRecord, TermRecord};

use crate::proc::{self, Facts, Pid};
use crate::resume::Flag;
use crate::term::TermHandle;

use super::Daemon;

impl Daemon {
    /// At a terminal's end, or a set that raced it: drops the command from
    /// the record kept on whichever board, unless the shutdown has begun.
    pub(super) async fn end_resume(&self, term_id: &str) {
        if self.shutting_down.load(Ordering::SeqCst) {
            return;
        }
        self.drop_resume(self.boards.lock().await.record_mut(term_id), None);
    }

    /// The one drop of a resume command, run with `boards` held: the
    /// command, and `handle`'s holder and flag; dirty, and true, when a
    /// command went.
    fn drop_resume(&self, record: Option<&mut TermRecord>, handle: Option<&TermHandle>) -> bool {
        if let Some(handle) = handle {
            handle.forget_resume();
        }
        let dropped = record.and_then(|r| r.resume.take()).is_some();
        if dropped {
            self.mark_dirty();
        }
        dropped
    }

    /// Tells the app that `term_id`'s command is now `cmd` (spec 2611.0015,
    /// D10). Not an event, so not `emit`; sent with `boards` released.
    async fn push_resume(&self, term_id: &str, cmd: Option<String>) {
        self.push(Msg::TermResume { term_id: term_id.into(), cmd }).await;
    }

    /// The answer to a cli `resume` (spec 2611.0011): `Err` is the `err` text.
    /// `cmd: None` clears. The command is checked before its holder is
    /// resolved, and no process is read while `boards` is held.
    pub async fn set_resume(&self, peer: Option<Pid>, term_id: &str, cmd: Option<String>) -> Result<(), String> {
        let unknown = || format!("unknown terminal: {term_id}");
        let handle = self.term(term_id).await.ok_or_else(unknown)?;
        let Some(cmd) = cmd else {
            self.drop_and_push(term_id, |record| self.drop_resume(record, Some(&handle))).await;
            return Ok(());
        };
        tarmac_protocol::refuse_resume_cmd(&cmd)?;
        let holder = handle
            .resolve_holder(peer)
            .and_then(|holder| crate::holder::tie(holder, proc::proc_facts))
            .ok_or_else(|| format!("no process to tie the resume command to in {term_id}"))?;
        let stored = self
            .with_record(term_id, |_, record| {
                let record = record?;
                handle.hold_resume(holder);
                let changed = record.resume.as_ref().is_none_or(|r| r.cmd != cmd);
                if changed {
                    record.resume = Some(ResumeRecord { cmd: cmd.clone() });
                    self.mark_dirty();
                }
                Some(changed)
            })
            .await;
        let Some(changed) = stored else { return Err(unknown()) };
        // A terminal that ended while this ran: `term_ended` took it out of
        // `terms` before its own drop, so one of the two finds the command.
        // Its `exit` ends the card, so no push.
        if self.term(term_id).await.is_none() {
            self.end_resume(term_id).await;
        } else if changed {
            self.push_resume(term_id, Some(cmd)).await;
        }
        Ok(())
    }

    /// Runs `drop` as `with_record` does and, when it dropped the command,
    /// tells the app, with `boards` released.
    async fn drop_and_push(&self, term_id: &str, drop: impl FnOnce(Option<&mut TermRecord>) -> bool) {
        if self.with_record(term_id, |_, record| drop(record)).await {
            self.push_resume(term_id, None).await;
        }
    }

    /// The poll's check: drops the resume command when its holder is gone,
    /// unless the shutdown has begun. The holder is read from the handle and
    /// checked with no lock held, and dropped only if it is still the one
    /// checked, so a `resume` set in between is never undone.
    pub async fn check_resume(&self, term_id: &str, handle: &TermHandle, facts_of: impl Fn(Pid) -> Facts) {
        if handle.resume_flag() != Flag::Held {
            return;
        }
        let Some(checked) = handle.resume_holder() else { return };
        if checked.alive(facts_of) {
            return;
        }
        self.drop_and_push(term_id, |record| {
            !self.shutting_down.load(Ordering::SeqCst)
                && handle.resume_holder() == Some(checked)
                && self.drop_resume(record, Some(handle))
        })
        .await;
    }

    /// Typed input drops a resume command that has no holder (D6).
    pub(super) async fn claim_resume(&self, term_id: &str, handle: &TermHandle) {
        if handle.resume_flag() != Flag::Unclaimed {
            return;
        }
        self.drop_and_push(term_id, |record| {
            handle.resume_flag() == Flag::Unclaimed && self.drop_resume(record, Some(handle))
        })
        .await;
    }

    /// The app's skip (spec 2611.0015, D4): the same drop as typed input, so
    /// a command an agent set since the restore (`Held`) is never undone. An
    /// unknown terminal is a no-op: app-session frames have no reply.
    pub async fn skip_resume(&self, term_id: &str) {
        if let Some(handle) = self.term(term_id).await {
            self.claim_resume(term_id, &handle).await;
        } else {
            tracing::debug!("resume skip for unknown term {term_id}");
        }
    }
}
