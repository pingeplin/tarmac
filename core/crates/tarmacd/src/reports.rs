//! Each live terminal's current report (spec 2611.0009): what it says, when,
//! and which process holds it. Pure: the clock and the process reads are
//! passed in. Never persisted: the processes it describes die with the daemon.

use std::collections::HashMap;

use tarmac_protocol::Msg;

use crate::agent::{Found, Pid};
use crate::proc::Facts;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Blocked,
    Done,
}

impl Kind {
    pub fn parse(kind: &str) -> Option<Kind> {
        match kind {
            "blocked" => Some(Kind::Blocked),
            "done" => Some(Kind::Done),
            _ => None,
        }
    }

    fn wire(self) -> &'static str {
        match self {
            Kind::Blocked => "blocked",
            Kind::Done => "done",
        }
    }
}

/// The process whose life the report lasts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Holder {
    /// `started` tells the process from a later one with the same pid.
    Agent { pid: Pid, started: u64 },
    /// A report typed at the prompt: it lasts while the leader is the shell
    /// `pid` or the reporting `caller`.
    Shell { pid: Pid, caller: Pid },
    Leader { pid: Pid },
}

impl Holder {
    pub fn pid(&self) -> Pid {
        match *self {
            Holder::Agent { pid, .. } | Holder::Shell { pid, .. } | Holder::Leader { pid } => pid,
        }
    }

    /// `leader` is a fresh foreground-leader read; `None` (a failed read)
    /// keeps the report for this tick, as `Facts::Unread` does.
    pub fn alive(&self, facts_of: impl Fn(Pid) -> Facts, leader: Option<Pid>) -> bool {
        match *self {
            Holder::Agent { pid, started } => match facts_of(pid) {
                Facts::Live { started: now, .. } => now == started,
                Facts::Gone => false,
                Facts::Unread => true,
            },
            Holder::Shell { pid, caller } => leader.is_none_or(|l| l == pid || l == caller),
            Holder::Leader { pid } => leader.is_none_or(|l| l == pid),
        }
    }
}

/// The holder of a report from the walk's result. `None`: no process to tie
/// it to. `leader` is read only in the fallback.
pub fn decide_holder(
    found: Found,
    child: Option<Pid>,
    peer: Option<Pid>,
    facts_of: impl Fn(Pid) -> Facts,
    leader: impl FnOnce() -> Option<Pid>,
) -> Option<Holder> {
    match (found, child, peer) {
        (Found::Agent(pid), _, _) => {
            if let Facts::Live { started, .. } = facts_of(pid) {
                return Some(Holder::Agent { pid, started });
            }
        }
        (Found::Shell, Some(pid), Some(caller)) => return Some(Holder::Shell { pid, caller }),
        _ => {}
    }
    leader().map(|pid| Holder::Leader { pid })
}

#[derive(Debug, Clone, PartialEq)]
struct CurrentReport {
    kind: Kind,
    text: Option<String>,
    at_ms: u64,
    holder: Holder,
    proc: Option<String>,
    read: bool,
}

/// Each method returns the `term_report` to push, or `None` when the app
/// needs nothing.
#[derive(Default)]
pub struct Reports {
    by_term: HashMap<String, CurrentReport>,
}

impl Reports {
    pub fn report(
        &mut self,
        term: &str,
        kind: Kind,
        text: Option<String>,
        now_ms: u64,
        holder: Holder,
        proc: Option<String>,
    ) -> Msg {
        let current = CurrentReport { kind, text, at_ms: now_ms, holder, proc, read: false };
        let msg = frame(term, Some(&current));
        self.by_term.insert(term.to_owned(), current);
        msg
    }

    pub fn clear(&mut self, term: &str) -> Option<Msg> {
        self.by_term.remove(term).map(|_| frame(term, None))
    }

    pub fn mark_read(&mut self, term: &str) -> Option<Msg> {
        let current = self.by_term.get_mut(term).filter(|r| !r.read)?;
        current.read = true;
        Some(frame(term, Some(current)))
    }

    pub fn check(&mut self, term: &str, alive: impl FnOnce(&Holder) -> bool) -> Option<Msg> {
        if alive(&self.by_term.get(term)?.holder) {
            return None;
        }
        self.clear(term)
    }

    /// At the terminal's exit; the app ends the report on its `exit` frame.
    pub fn forget(&mut self, term: &str) {
        self.by_term.remove(term);
    }

    /// One frame for each of `terms`: its report, or one with no `kind`.
    pub fn snapshot(&self, terms: &[String]) -> Vec<Msg> {
        terms.iter().map(|term| frame(term, self.by_term.get(term))).collect()
    }

    pub fn has(&self, term: &str) -> bool {
        self.by_term.contains_key(term)
    }

    pub fn unread(&self, term: &str) -> bool {
        self.by_term.get(term).is_some_and(|r| !r.read)
    }
}

fn frame(term: &str, report: Option<&CurrentReport>) -> Msg {
    Msg::TermReport {
        term_id: term.to_owned(),
        kind: report.map(|r| r.kind.wire().to_owned()),
        text: report.and_then(|r| r.text.clone()),
        at_ms: report.map(|r| r.at_ms),
        proc: report.and_then(|r| r.proc.clone()),
        read: report.is_some_and(|r| r.read),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: &str = "t1";
    const S: Pid = 100;
    const C: Pid = 500;
    const L: Pid = 700;
    const AGENT: Holder = Holder::Agent { pid: 200, started: 11 };

    fn frame(kind: &str, text: Option<&str>, at_ms: u64, proc: Option<&str>, read: bool) -> Msg {
        Msg::TermReport {
            term_id: T.into(),
            kind: Some(kind.into()),
            text: text.map(str::to_string),
            at_ms: Some(at_ms),
            proc: proc.map(str::to_string),
            read,
        }
    }

    fn none_frame(term: &str) -> Msg {
        Msg::TermReport { term_id: term.into(), kind: None, text: None, at_ms: None, proc: None, read: false }
    }

    fn blocked(reports: &mut Reports, now_ms: u64) -> Msg {
        reports.report(T, Kind::Blocked, Some("ok?".into()), now_ms, AGENT, Some("claude".into()))
    }

    fn facts(pairs: &[(Pid, Facts)]) -> impl Fn(Pid) -> Facts + use<> {
        let pairs = pairs.to_vec();
        move |pid| pairs.iter().find(|(p, _)| *p == pid).map_or(Facts::Gone, |(_, f)| *f)
    }

    fn live(started: u64) -> Facts {
        Facts::Live { ppid: 1, started }
    }

    #[test]
    fn s11a_a_first_report_is_pushed_unread() {
        let mut reports = Reports::default();
        assert_eq!(blocked(&mut reports, 1000), frame("blocked", Some("ok?"), 1000, Some("claude"), false));
        assert!(reports.has(T) && reports.unread(T));
    }

    #[test]
    fn s11b_an_identical_repeat_is_a_new_unread_report_with_the_new_holder() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        reports.mark_read(T);
        let shell = Holder::Shell { pid: S, caller: C };

        let again = reports.report(T, Kind::Blocked, Some("ok?".into()), 2000, shell, Some("bash".into()));

        assert_eq!(again, frame("blocked", Some("ok?"), 2000, Some("bash"), false));
        assert_eq!(reports.by_term[T].holder, shell);
        assert!(reports.unread(T));
    }

    #[test]
    fn s11c_a_repeat_with_a_new_text_is_unread() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        reports.mark_read(T);
        let again = reports.report(T, Kind::Done, Some("new".into()), 1500, AGENT, None);
        assert_eq!(again, frame("done", Some("new"), 1500, None, false));
    }

    #[test]
    fn s11d_clear_pushes_a_removal_only_when_there_was_a_report() {
        let mut reports = Reports::default();
        assert_eq!(reports.clear(T), None);
        blocked(&mut reports, 1000);
        assert_eq!(reports.clear(T), Some(none_frame(T)));
        assert!(!reports.has(T) && !reports.unread(T));
        assert_eq!(reports.clear(T), None);
    }

    #[test]
    fn s11e_mark_read_pushes_once() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        assert_eq!(reports.mark_read(T), Some(frame("blocked", Some("ok?"), 1000, Some("claude"), true)));
        assert!(!reports.unread(T) && reports.has(T));
        assert_eq!(reports.mark_read(T), None);
    }

    #[test]
    fn s11f_check_removes_a_report_whose_holder_is_gone_once() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        assert_eq!(reports.check(T, |_| true), None);
        assert!(reports.has(T));
        assert_eq!(reports.check(T, |_| false), Some(none_frame(T)));
        assert!(!reports.has(T));
        assert_eq!(reports.check(T, |_| false), None);
    }

    #[test]
    fn s11g_forget_pushes_nothing_and_empties_the_store() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        reports.forget(T);
        assert!(!reports.has(T));
        assert_eq!(reports.snapshot(&[T.into()]), vec![none_frame(T)]);
    }

    #[test]
    fn s11h_a_shell_holder_lasts_while_the_leader_is_the_shell_or_the_caller() {
        let mut reports = Reports::default();
        reports.report(T, Kind::Done, None, 1000, Holder::Shell { pid: S, caller: C }, None);
        let no_facts = facts(&[]);
        for leader in [Some(S), Some(C), None] {
            assert_eq!(reports.check(T, |h| h.alive(&no_facts, leader)), None, "{leader:?}");
        }
        assert_eq!(reports.check(T, |h| h.alive(&no_facts, Some(L))), Some(none_frame(T)));
    }

    #[test]
    fn s11i_a_snapshot_has_one_frame_for_each_term() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        assert_eq!(
            reports.snapshot(&[T.into(), "u1".into()]),
            vec![frame("blocked", Some("ok?"), 1000, Some("claude"), false), none_frame("u1")]
        );
    }

    #[test]
    fn s12_an_agent_holder_lasts_while_its_process_with_that_start_time_lives() {
        let agent = Holder::Agent { pid: 200, started: 11 };
        assert!(agent.alive(facts(&[(200, live(11))]), Some(L)));
        assert!(!agent.alive(facts(&[(200, live(12))]), Some(L)), "a reused pid");
        assert!(agent.alive(facts(&[(200, Facts::Unread)]), Some(L)));
        assert!(!agent.alive(facts(&[(200, Facts::Gone)]), Some(L)));
        assert!(!agent.alive(facts(&[(200, Facts::Gone)]), None), "a failed leader read does not keep it");
    }

    #[test]
    fn s12_check_removes_a_report_whose_agent_pid_was_reused() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        let reused = facts(&[(200, live(12))]);
        assert_eq!(reports.check(T, |h| h.alive(&reused, Some(L))), Some(none_frame(T)));
    }

    #[test]
    fn s12_a_leader_holder_lasts_while_it_is_the_leader() {
        let leader = Holder::Leader { pid: L };
        assert!(leader.alive(facts(&[]), Some(L)));
        assert!(leader.alive(facts(&[]), None));
        assert!(!leader.alive(facts(&[]), Some(S)));
    }

    #[test]
    fn s36_an_agent_with_live_facts_is_held_with_its_start_time() {
        let holder = decide_holder(Found::Agent(200), Some(S), Some(C), facts(&[(200, live(11))]), || Some(L));
        assert_eq!(holder, Some(Holder::Agent { pid: 200, started: 11 }));
    }

    #[test]
    fn s36_an_agent_whose_facts_are_not_live_falls_back_to_the_leader() {
        for f in [Facts::Gone, Facts::Unread] {
            let holder = decide_holder(Found::Agent(200), Some(S), Some(C), facts(&[(200, f)]), || Some(L));
            assert_eq!(holder, Some(Holder::Leader { pid: L }), "{f:?}");
        }
    }

    #[test]
    fn s36_the_shell_holds_a_report_typed_at_the_prompt() {
        let holder = decide_holder(Found::Shell, Some(S), Some(C), facts(&[]), || panic!("no leader read"));
        assert_eq!(holder, Some(Holder::Shell { pid: S, caller: C }));
    }

    #[test]
    fn s36_an_unattributed_caller_falls_back_to_the_leader_or_to_none() {
        assert_eq!(
            decide_holder(Found::Unattributed, Some(S), Some(C), facts(&[]), || Some(L)),
            Some(Holder::Leader { pid: L })
        );
        assert_eq!(decide_holder(Found::Unattributed, Some(S), None, facts(&[]), || None), None);
    }

    #[test]
    fn a_kind_is_blocked_or_done() {
        assert_eq!(Kind::parse("blocked"), Some(Kind::Blocked));
        assert_eq!(Kind::parse("done"), Some(Kind::Done));
        assert_eq!(Kind::parse("clear"), None);
        assert_eq!(Kind::parse("later"), None);
    }
}
