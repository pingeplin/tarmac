//! Each live terminal's current report (spec 2611.0009): what it says, when,
//! and which process holds it. Pure: the clock and the process reads are
//! passed in. Never persisted: the processes it describes die with the daemon.

use std::collections::HashMap;

use tarmac_protocol::Msg;

use crate::holder::Holder;

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

/// Where the terminal was when it reported (spec 2611.0013): the board it is
/// filed under and its `last_cwd` record.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Place {
    pub board_id: Option<String>,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
struct CurrentReport {
    kind: Kind,
    text: Option<String>,
    at_ms: u64,
    holder: Holder,
    proc: Option<String>,
    read: bool,
    place: Place,
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
        place: Place,
    ) -> Msg {
        let current = CurrentReport { kind, text, at_ms: now_ms, holder, proc, read: false, place };
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

    /// The connect replay (2611.0013): one frame for each term that has a
    /// report and is not in `shown`, sorted by term id.
    pub fn elsewhere(&self, shown: &[String]) -> Vec<Msg> {
        let mut terms: Vec<&String> = self.by_term.keys().filter(|t| !shown.contains(t)).collect();
        terms.sort();
        terms.into_iter().map(|term| frame(term, self.by_term.get(term))).collect()
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
        board_id: report.and_then(|r| r.place.board_id.clone()),
        cwd: report.and_then(|r| r.place.cwd.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::{L, S, facts, live};
    use crate::proc::Pid;

    const T: &str = "t1";
    const C: Pid = 500;
    const AGENT: Holder = Holder::Agent { pid: 200, started: 11 };

    fn report_frame(term: &str, kind: &str, text: Option<&str>, at_ms: u64, proc: Option<&str>, read: bool, place: Place) -> Msg {
        Msg::TermReport {
            term_id: term.into(),
            kind: Some(kind.into()),
            text: text.map(str::to_string),
            at_ms: Some(at_ms),
            proc: proc.map(str::to_string),
            read,
            board_id: place.board_id,
            cwd: place.cwd,
        }
    }

    fn none_frame(term: &str) -> Msg {
        Msg::TermReport { term_id: term.into(), kind: None, text: None, at_ms: None, proc: None, read: false, board_id: None, cwd: None }
    }

    fn blocked(reports: &mut Reports, now_ms: u64) -> Msg {
        reports.report(T, Kind::Blocked, Some("ok?".into()), now_ms, AGENT, Some("claude".into()), Place::default())
    }

    fn on_board(board: &str, cwd: &str) -> Place {
        Place { board_id: Some(board.into()), cwd: Some(cwd.into()) }
    }

    #[test]
    fn s11a_a_first_report_is_pushed_unread() {
        let mut reports = Reports::default();
        assert_eq!(blocked(&mut reports, 1000), report_frame(T, "blocked", Some("ok?"), 1000, Some("claude"), false, Place::default()));
        assert!(reports.has(T) && reports.unread(T));
    }

    #[test]
    fn s11b_an_identical_repeat_is_a_new_unread_report_with_the_new_holder() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        reports.mark_read(T);
        let shell = Holder::Shell { pid: S, caller: C };

        let again = reports.report(T, Kind::Blocked, Some("ok?".into()), 2000, shell, Some("bash".into()), Place::default());

        assert_eq!(again, report_frame(T, "blocked", Some("ok?"), 2000, Some("bash"), false, Place::default()));
        assert_eq!(reports.by_term[T].holder, shell);
        assert!(reports.unread(T));
    }

    #[test]
    fn s11c_a_repeat_with_a_new_text_is_unread() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        reports.mark_read(T);
        let again = reports.report(T, Kind::Done, Some("new".into()), 1500, AGENT, None, Place::default());
        assert_eq!(again, report_frame(T, "done", Some("new"), 1500, None, false, Place::default()));
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
        assert_eq!(reports.mark_read(T), Some(report_frame(T, "blocked", Some("ok?"), 1000, Some("claude"), true, Place::default())));
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
        reports.report(T, Kind::Done, None, 1000, Holder::Shell { pid: S, caller: C }, None, Place::default());
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
            vec![report_frame(T, "blocked", Some("ok?"), 1000, Some("claude"), false, Place::default()), none_frame("u1")]
        );
    }

    #[test]
    fn s12_check_removes_a_report_whose_agent_pid_was_reused() {
        let mut reports = Reports::default();
        blocked(&mut reports, 1000);
        let reused = facts(&[(200, live(12))]);
        assert_eq!(reports.check(T, |h| h.alive(&reused, Some(L))), Some(none_frame(T)));
    }

    // 2611.0013 S14
    #[test]
    fn s14_the_frame_carries_the_place_given_to_report_and_keeps_it_when_read() {
        let mut reports = Reports::default();
        let pushed = reports.report(T, Kind::Done, None, 1000, AGENT, None, on_board("board-1", "/w"));
        assert_eq!(pushed, report_frame(T, "done", None, 1000, None, false, on_board("board-1", "/w")));
        assert_eq!(reports.mark_read(T), Some(report_frame(T, "done", None, 1000, None, true, on_board("board-1", "/w"))));
        assert_eq!(reports.clear(T), Some(none_frame(T)), "a removal has no place");
    }

    // 2611.0013 S14
    #[test]
    fn s14_elsewhere_gives_each_reported_term_not_shown_sorted_by_term_id() {
        let mut reports = Reports::default();
        reports.report("u", Kind::Done, None, 2000, AGENT, None, on_board("board-2", "/u"));
        reports.report("t", Kind::Blocked, None, 1000, AGENT, None, on_board("board-1", "/t"));
        let t = report_frame("t", "blocked", None, 1000, None, false, on_board("board-1", "/t"));
        let u = report_frame("u", "done", None, 2000, None, false, on_board("board-2", "/u"));

        assert_eq!(reports.elsewhere(&["u".into(), "a".into()]), vec![t.clone()]);
        assert_eq!(reports.elsewhere(&[]), vec![t, u]);
    }

    #[test]
    fn a_kind_is_blocked_or_done() {
        assert_eq!(Kind::parse("blocked"), Some(Kind::Blocked));
        assert_eq!(Kind::parse("done"), Some(Kind::Done));
        assert_eq!(Kind::parse("clear"), None);
        assert_eq!(Kind::parse("later"), None);
    }
}
