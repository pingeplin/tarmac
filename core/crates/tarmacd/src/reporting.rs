//! The daemon's side of a terminal's report (spec 2611.0009): the `report`
//! handler, the poll's lifetime check and the read on typed input. The
//! decisions are in `agent` and `reports`; this is the wiring around them.
//!
//! Each change, the two flags on its `TermHandle` and its push happen under the
//! `reports` lock. `terms` is never taken while that lock is held.

use std::time::SystemTime;

use tarmac_protocol::cap_report_text;

use crate::agent::{self, Pid};
use crate::boards::epoch_ms;
use crate::proc::{self, Facts};
use crate::reports::{self, Kind, Reports};
use crate::state::Daemon;
use crate::term::TermHandle;

fn parent_of(pid: Pid) -> Option<Pid> {
    match proc::proc_facts(pid) {
        Facts::Live { ppid, .. } => Some(ppid),
        Facts::Gone | Facts::Unread => None,
    }
}

fn sync_flags(handle: &TermHandle, reports: &Reports, term_id: &str) {
    handle.set_report_flags(reports.has(term_id), reports.unread(term_id));
}

/// The answer to a cli `report`: `Err` is the `err` text.
pub async fn handle_report(
    daemon: &Daemon,
    peer: Option<Pid>,
    term_id: &str,
    kind: &str,
    text: Option<String>,
) -> Result<(), String> {
    let handle = daemon.term(term_id).await.ok_or_else(|| format!("unknown terminal: {term_id}"))?;
    if kind == "clear" {
        let mut reports = daemon.reports.lock().await;
        let msg = reports.clear(term_id);
        sync_flags(&handle, &reports, term_id);
        if let Some(msg) = msg {
            daemon.push(msg).await;
        }
        return Ok(());
    }
    let kind = Kind::parse(kind).ok_or_else(|| format!("unknown report kind: {kind}"))?;
    // Any socket client can send a `report`, so the daemon caps it too.
    let text = text.map(|t| cap_report_text(&t)).filter(|t| !t.is_empty());
    let found = agent::find_agent(peer, handle.pid(), handle.spawned_with_cmd(), parent_of);
    let holder = reports::decide_holder(found, handle.pid(), peer, proc::proc_facts, || handle.foreground_pid())
        .ok_or_else(|| format!("no process to tie the report to in {term_id}"))?;
    let proc_name = proc::process_name(holder.pid());
    {
        let mut reports = daemon.reports.lock().await;
        let msg = reports.report(term_id, kind, text, epoch_ms(SystemTime::now()), holder, proc_name);
        sync_flags(&handle, &reports, term_id);
        daemon.push(msg).await;
    }
    // A terminal that exited while this ran: `term_ended` took it out of
    // `terms` before its own `forget`, so one of the two finds the entry.
    if daemon.term(term_id).await.is_none() {
        daemon.reports.lock().await.forget(term_id);
    }
    Ok(())
}

/// The poll's check: removes the report when its holder is gone.
pub async fn check(daemon: &Daemon, term_id: &str, handle: &TermHandle) {
    if !handle.has_report() {
        return;
    }
    let mut reports = daemon.reports.lock().await;
    let msg = reports.check(term_id, |holder| holder.alive(proc::proc_facts, handle.foreground_pid()));
    sync_flags(handle, &reports, term_id);
    if let Some(msg) = msg {
        daemon.push(msg).await;
    }
}

/// Typed input marks an unread report read. One atomic load when there is none.
pub async fn mark_read(daemon: &Daemon, term_id: &str, handle: &TermHandle) {
    if !handle.unread_report() {
        return;
    }
    let mut reports = daemon.reports.lock().await;
    let msg = reports.mark_read(term_id);
    sync_flags(handle, &reports, term_id);
    if let Some(msg) = msg {
        daemon.push(msg).await;
    }
}
