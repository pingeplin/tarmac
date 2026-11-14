//! Each live terminal's current report (spec 2611.0009): what it says, when,
//! and which process holds it. Pure: the clock and the process reads are
//! passed in. Never persisted: the processes it describes die with the daemon.

use std::collections::HashMap;

use tarmac_protocol::Msg;

use crate::proc::{Facts, Pid};

/// The longest chain the walk follows, caller and PTY child included: a guard
/// against a cycle.
const MAX_HOPS: usize = 32;

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
    /// The holder of a report from a client whose pid is `caller`, in a
    /// terminal whose PTY child is `child`: the walk up `caller`'s parents to
    /// `child`. A child spawned with a `cmd` (`child_is_cmd`) is the agent for
    /// every caller. Else the member just below the child is the agent, or the
    /// shell holds it when the caller is the child or the child's child (a
    /// report typed at the prompt; the cli exits right after its answer, so it
    /// is never the agent). A caller the walk cannot place (no pid, a parent
    /// gone or unread, pid 1 reached, or a chain of more than `MAX_HOPS`)
    /// falls back to the foreground `leader`, read only then. `None`: no
    /// process to tie the report to.
    pub fn resolve(
        caller: Option<Pid>,
        child: Option<Pid>,
        child_is_cmd: bool,
        facts_of: impl Fn(Pid) -> Facts,
        leader: impl FnOnce() -> Option<Pid>,
    ) -> Option<Holder> {
        Self::walk(caller, child, child_is_cmd, facts_of).or_else(|| leader().map(|pid| Holder::Leader { pid }))
    }

    fn walk(caller: Option<Pid>, child: Option<Pid>, child_is_cmd: bool, facts_of: impl Fn(Pid) -> Facts) -> Option<Holder> {
        let (caller, child) = (caller?, child?);
        let (mut pid, mut below, mut members) = (caller, None, 1);
        while pid != child {
            if pid <= 1 || members == MAX_HOPS {
                return None;
            }
            let Facts::Live { ppid, started } = facts_of(pid) else { return None };
            below = Some((pid, started));
            pid = ppid;
            members += 1;
        }
        if child_is_cmd {
            let Facts::Live { started, .. } = facts_of(child) else { return None };
            return Some(Holder::Agent { pid: child, started });
        }
        match below {
            Some((pid, started)) if pid != caller => Some(Holder::Agent { pid, started }),
            _ => Some(Holder::Shell { pid: child, caller }),
        }
    }

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

    // The walk: S9 and S36, against the production `Holder::resolve`.
    const CHILD: Pid = 100;
    const A: Pid = 200;
    const X: Pid = 300;
    const Y: Pid = 400;
    const CALLER: Pid = 500;
    const CHAIN: &[(Pid, Pid)] = &[(CALLER, X), (X, A), (A, CHILD), (CHILD, 1)];

    /// A process table: each pid's parent; every pid in it started at its own
    /// pid, and any other is gone.
    fn table(parents: &[(Pid, Pid)]) -> impl Fn(Pid) -> Facts + use<> {
        let parents = parents.to_vec();
        move |pid| {
            parents.iter().find(|(p, _)| *p == pid).map_or(Facts::Gone, |&(_, ppid)| Facts::Live { ppid, started: pid as u64 })
        }
    }

    fn resolve(caller: Pid, cmd: bool, parents: &[(Pid, Pid)]) -> Option<Holder> {
        Holder::resolve(Some(caller), Some(CHILD), cmd, table(parents), || Some(L))
    }

    fn agent(pid: Pid) -> Option<Holder> {
        Some(Holder::Agent { pid, started: pid as u64 })
    }

    const LEADER: Option<Holder> = Some(Holder::Leader { pid: L });

    #[test]
    fn s9a_the_agent_is_the_member_just_below_the_shell() {
        assert_eq!(resolve(CALLER, false, CHAIN), agent(A));
    }

    #[test]
    fn s9b_s36_a_caller_whose_parent_is_the_shell_is_held_by_the_shell() {
        let shell = Holder::resolve(Some(CALLER), Some(CHILD), false, table(&[(CALLER, CHILD)]), || panic!("no leader read"));
        assert_eq!(shell, Some(Holder::Shell { pid: CHILD, caller: CALLER }));
    }

    #[test]
    fn s9c_the_shell_itself_as_the_caller_is_held_by_the_shell() {
        assert_eq!(resolve(CHILD, false, &[(CHILD, 1)]), Some(Holder::Shell { pid: CHILD, caller: CHILD }));
    }

    #[test]
    fn s9d_s9i_a_child_spawned_as_cmd_is_the_agent_for_every_caller() {
        assert_eq!(resolve(CALLER, true, CHAIN), agent(CHILD));
        assert_eq!(resolve(CALLER, true, &[(CALLER, CHILD), (CHILD, 1)]), agent(CHILD));
    }

    #[test]
    fn s36_a_cmd_child_whose_facts_are_not_live_falls_back_to_the_leader() {
        let parents = [(CALLER, CHILD)];
        for f in [Facts::Gone, Facts::Unread] {
            let facts_of = |pid| if pid == CHILD { f } else { table(&parents)(pid) };
            assert_eq!(Holder::resolve(Some(CALLER), Some(CHILD), true, facts_of, || Some(L)), LEADER, "{f:?}");
        }
    }

    #[test]
    fn s9e_a_caller_re_parented_to_launchd_falls_back_to_the_leader() {
        // A parent of pid 1 that leads to the child: only the guard stops there.
        assert_eq!(resolve(CALLER, false, &[(CALLER, X), (X, 1), (1, CHILD)]), LEADER);
    }

    #[test]
    fn s9f_s36_a_parent_gone_or_unread_on_the_way_falls_back_to_the_leader() {
        assert_eq!(resolve(CALLER, false, &[(CALLER, X)]), LEADER);
        let unread = |pid| if pid == X { Facts::Unread } else { table(CHAIN)(pid) };
        assert_eq!(Holder::resolve(Some(CALLER), Some(CHILD), false, unread, || Some(L)), LEADER);
    }

    #[test]
    fn s9g_no_caller_or_no_child_falls_back_to_the_leader() {
        assert_eq!(Holder::resolve(None, Some(CHILD), false, table(CHAIN), || Some(L)), LEADER);
        assert_eq!(Holder::resolve(Some(CALLER), None, false, table(CHAIN), || Some(L)), LEADER);
    }

    #[test]
    fn s9h_a_cycle_falls_back_to_the_leader() {
        assert_eq!(resolve(CALLER, false, &[(CALLER, X), (X, Y), (Y, X)]), LEADER);
    }

    /// A chain of `members` pids, the caller first and the child last.
    fn chain_of(members: usize) -> (Pid, Vec<(Pid, Pid)>) {
        let pids: Vec<Pid> = (0..members - 1).map(|i| 1000 + i as Pid).chain([CHILD]).collect();
        (pids[0], pids.windows(2).map(|w| (w[0], w[1])).collect())
    }

    #[test]
    fn s9h_a_chain_of_32_members_is_walked() {
        let (caller, parents) = chain_of(32);
        assert_eq!(resolve(caller, false, &parents), agent(parents[parents.len() - 1].0));
    }

    #[test]
    fn s9h_a_chain_of_33_members_falls_back_to_the_leader() {
        let (caller, parents) = chain_of(33);
        assert_eq!(resolve(caller, false, &parents), LEADER);
    }

    #[test]
    fn s36_an_unplaced_caller_with_no_leader_has_no_holder() {
        assert_eq!(Holder::resolve(None, Some(CHILD), false, table(CHAIN), || None), None);
    }

    #[test]
    fn a_kind_is_blocked_or_done() {
        assert_eq!(Kind::parse("blocked"), Some(Kind::Blocked));
        assert_eq!(Kind::parse("done"), Some(Kind::Done));
        assert_eq!(Kind::parse("clear"), None);
        assert_eq!(Kind::parse("later"), None);
    }
}
