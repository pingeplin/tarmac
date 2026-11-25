//! The process a report or a resume command lasts for: how it is found from
//! the client's pid, and when it is gone. Pure: the process reads are passed in.

use crate::proc::{Facts, Pid};

/// The longest chain the walk follows, caller and PTY child included: a guard
/// against a cycle.
const MAX_HOPS: usize = 32;

/// The process whose life the report lasts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Holder {
    /// `started` tells the process from a later one with the same pid.
    Agent {
        pid: Pid,
        started: u64,
    },
    /// A report typed at the prompt: it lasts while the leader is the shell
    /// `pid` or the reporting `caller`.
    Shell {
        pid: Pid,
        caller: Pid,
    },
    Leader {
        pid: Pid,
    },
}

/// A process told from a later one with the same pid by its start time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct StartedPid {
    pub pid: Pid,
    pub started: u64,
}

impl StartedPid {
    /// `Unread` keeps it.
    pub(crate) fn alive(&self, facts_of: impl Fn(Pid) -> Facts) -> bool {
        match facts_of(self.pid) {
            Facts::Live { started, .. } => started == self.started,
            Facts::Gone => false,
            Facts::Unread => true,
        }
    }
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
    pub(crate) fn resolve(
        caller: Option<Pid>,
        child: Option<Pid>,
        child_is_cmd: bool,
        facts_of: impl Fn(Pid) -> Facts,
        leader: impl FnOnce() -> Option<Pid>,
    ) -> Option<Holder> {
        Self::walk(caller, child, child_is_cmd, facts_of).or_else(|| leader().map(|pid| Holder::Leader { pid }))
    }

    fn walk(
        caller: Option<Pid>,
        child: Option<Pid>,
        child_is_cmd: bool,
        facts_of: impl Fn(Pid) -> Facts,
    ) -> Option<Holder> {
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

    pub(crate) fn pid(&self) -> Pid {
        match *self {
            Holder::Agent { pid, .. } | Holder::Shell { pid, .. } | Holder::Leader { pid } => pid,
        }
    }

    /// `leader` is a fresh foreground-leader read; `None` (a failed read)
    /// keeps the report for this tick, as `Facts::Unread` does.
    pub(crate) fn alive(&self, facts_of: impl Fn(Pid) -> Facts, leader: Option<Pid>) -> bool {
        match *self {
            Holder::Agent { pid, started } => StartedPid { pid, started }.alive(facts_of),
            Holder::Shell { pid, caller } => leader.is_none_or(|l| l == pid || l == caller),
            Holder::Leader { pid } => leader.is_none_or(|l| l == pid),
        }
    }
}

/// The holder of a resume command is always a pid with its start time (D2):
/// a command lasts for a process's life, not until the next foreground job.
/// So the shell itself holds one set at the prompt, and the leader the
/// fallback's. `None` when that process cannot be read.
pub(crate) fn tie(holder: Holder, facts_of: impl Fn(Pid) -> Facts) -> Option<StartedPid> {
    match holder {
        Holder::Agent { pid, started } => Some(StartedPid { pid, started }),
        Holder::Shell { pid, .. } | Holder::Leader { pid } => match facts_of(pid) {
            Facts::Live { started, .. } => Some(StartedPid { pid, started }),
            Facts::Gone | Facts::Unread => None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::{L, S, facts, live};

    /// "Holder liveness rejects a reused pid".
    #[test]
    fn an_agent_holder_lasts_while_its_process_with_that_start_time_lives() {
        let agent = Holder::Agent { pid: 200, started: 11 };
        assert!(agent.alive(facts(&[(200, live(11))]), Some(L)));
        assert!(!agent.alive(facts(&[(200, live(12))]), Some(L)), "a reused pid");
        assert!(agent.alive(facts(&[(200, Facts::Unread)]), Some(L)));
        assert!(!agent.alive(facts(&[(200, Facts::Gone)]), Some(L)));
        assert!(!agent.alive(facts(&[(200, Facts::Gone)]), None), "a failed leader read does not keep it");
    }

    /// "Holder liveness rejects a reused pid".
    #[test]
    fn a_leader_holder_lasts_while_it_is_the_leader() {
        let leader = Holder::Leader { pid: L };
        assert!(leader.alive(facts(&[]), Some(L)));
        assert!(leader.alive(facts(&[]), None));
        assert!(!leader.alive(facts(&[]), Some(S)));
    }

    // The walk: "Agent walk resolves each parent chain case" and "Holder decision picks agent leader shell or none", against the production `Holder::resolve`.
    const CHILD: Pid = 100;
    const A: Pid = 200;
    const X: Pid = 300;
    const Y: Pid = 400;
    const CALLER: Pid = 500;
    const CHAIN: &[(Pid, Pid)] = &[(CALLER, X), (X, A), (A, CHILD), (CHILD, 1)];

    /// A process table: each pid's parent; every pid in it started at its own
    /// pid, and any other is gone. A walk reads at most `MAX_HOPS` of it, so
    /// one more read panics: a walk that would not end fails at once.
    fn table(parents: &[(Pid, Pid)]) -> impl Fn(Pid) -> Facts + use<> {
        let parents = parents.to_vec();
        let reads = std::cell::Cell::new(0);
        move |pid| {
            reads.set(reads.get() + 1);
            assert!(reads.get() <= MAX_HOPS, "a walk read the table {} times", reads.get());
            parents.iter().find(|(p, _)| *p == pid).map_or(Facts::Gone, |&(_, ppid)| Facts::Live {
                ppid,
                #[expect(clippy::cast_sign_loss, reason = "the tests' pids are positive")]
                started: pid as u64,
            })
        }
    }

    fn resolve(caller: Pid, cmd: bool, parents: &[(Pid, Pid)]) -> Option<Holder> {
        Holder::resolve(Some(caller), Some(CHILD), cmd, table(parents), || Some(L))
    }

    fn agent(pid: Pid) -> Option<Holder> {
        Some(Holder::Agent {
            pid,
            #[expect(clippy::cast_sign_loss, reason = "the tests' pids are positive")]
            started: pid as u64,
        })
    }

    const LEADER: Option<Holder> = Some(Holder::Leader { pid: L });

    /// "Agent walk resolves each parent chain case" (a).
    #[test]
    fn the_agent_is_the_member_just_below_the_shell() {
        assert_eq!(resolve(CALLER, false, CHAIN), agent(A));
    }

    /// "Agent walk resolves each parent chain case" (b), "Holder decision picks agent leader shell or none".
    #[test]
    fn a_caller_whose_parent_is_the_shell_is_held_by_the_shell() {
        let shell =
            Holder::resolve(Some(CALLER), Some(CHILD), false, table(&[(CALLER, CHILD)]), || panic!("no leader read"));
        assert_eq!(shell, Some(Holder::Shell { pid: CHILD, caller: CALLER }));
    }

    /// "Agent walk resolves each parent chain case" (c).
    #[test]
    fn the_shell_itself_as_the_caller_is_held_by_the_shell() {
        assert_eq!(resolve(CHILD, false, &[(CHILD, 1)]), Some(Holder::Shell { pid: CHILD, caller: CHILD }));
    }

    /// "Agent walk resolves each parent chain case" (d, i).
    #[test]
    fn a_child_spawned_as_cmd_is_the_agent_for_every_caller() {
        assert_eq!(resolve(CALLER, true, CHAIN), agent(CHILD));
        assert_eq!(resolve(CALLER, true, &[(CALLER, CHILD), (CHILD, 1)]), agent(CHILD));
    }

    /// "Holder decision picks agent leader shell or none".
    #[test]
    fn a_cmd_child_whose_facts_are_not_live_falls_back_to_the_leader() {
        let parents = [(CALLER, CHILD)];
        for f in [Facts::Gone, Facts::Unread] {
            let facts_of = |pid| if pid == CHILD { f } else { table(&parents)(pid) };
            assert_eq!(Holder::resolve(Some(CALLER), Some(CHILD), true, facts_of, || Some(L)), LEADER, "{f:?}");
        }
    }

    /// "Agent walk resolves each parent chain case" (e).
    #[test]
    fn a_caller_re_parented_to_launchd_falls_back_to_the_leader() {
        // A parent of pid 1 that leads to the child: only the guard stops there.
        assert_eq!(resolve(CALLER, false, &[(CALLER, X), (X, 1), (1, CHILD)]), LEADER);
    }

    /// "Agent walk resolves each parent chain case" (f), "Holder decision picks agent leader shell or none".
    #[test]
    fn a_parent_gone_or_unread_on_the_way_falls_back_to_the_leader() {
        assert_eq!(resolve(CALLER, false, &[(CALLER, X)]), LEADER);
        let unread = |pid| if pid == X { Facts::Unread } else { table(CHAIN)(pid) };
        assert_eq!(Holder::resolve(Some(CALLER), Some(CHILD), false, unread, || Some(L)), LEADER);
    }

    /// "Agent walk resolves each parent chain case" (g).
    #[test]
    fn no_caller_or_no_child_falls_back_to_the_leader() {
        assert_eq!(Holder::resolve(None, Some(CHILD), false, table(CHAIN), || Some(L)), LEADER);
        assert_eq!(Holder::resolve(Some(CALLER), None, false, table(CHAIN), || Some(L)), LEADER);
    }

    /// "Agent walk resolves each parent chain case" (h).
    #[test]
    fn a_cycle_falls_back_to_the_leader() {
        assert_eq!(resolve(CALLER, false, &[(CALLER, X), (X, Y), (Y, X)]), LEADER);
    }

    /// A chain of `members` pids, the caller first and the child last.
    fn chain_of(members: usize) -> (Pid, Vec<(Pid, Pid)>) {
        let pids: Vec<Pid> = (1000..).take(members - 1).chain([CHILD]).collect();
        (pids[0], pids.windows(2).map(|w| (w[0], w[1])).collect())
    }

    /// "Agent walk resolves each parent chain case" (h).
    #[test]
    fn a_chain_of_32_members_is_walked() {
        let (caller, parents) = chain_of(32);
        assert_eq!(resolve(caller, false, &parents), agent(parents[parents.len() - 1].0));
    }

    /// "Agent walk resolves each parent chain case" (h).
    #[test]
    fn a_chain_of_33_members_falls_back_to_the_leader() {
        let (caller, parents) = chain_of(33);
        assert_eq!(resolve(caller, false, &parents), LEADER);
    }

    /// "Holder decision picks agent leader shell or none".
    #[test]
    fn an_unplaced_caller_with_no_leader_has_no_holder() {
        assert_eq!(Holder::resolve(None, Some(CHILD), false, table(CHAIN), || None), None);
    }
}

#[cfg(test)]
mod tie_tests {
    use super::*;

    fn table(pid: Pid, facts: Facts) -> impl Fn(Pid) -> Facts {
        move |p| if p == pid { facts } else { Facts::Gone }
    }

    #[test]
    fn an_agent_stays_as_it_is() {
        let agent = Holder::Agent { pid: 200, started: 11 };
        assert_eq!(tie(agent, |_| Facts::Gone), Some(StartedPid { pid: 200, started: 11 }));
    }

    #[test]
    fn a_shell_or_a_leader_is_tied_to_its_own_start_time() {
        let facts = table(100, Facts::Live { ppid: 1, started: 7 });
        assert_eq!(tie(Holder::Shell { pid: 100, caller: 500 }, &facts), Some(StartedPid { pid: 100, started: 7 }));
        assert_eq!(tie(Holder::Leader { pid: 100 }, &facts), Some(StartedPid { pid: 100, started: 7 }));
    }

    #[test]
    fn a_shell_or_a_leader_that_cannot_be_read_ties_nothing() {
        for facts in [Facts::Gone, Facts::Unread] {
            assert_eq!(tie(Holder::Leader { pid: 100 }, table(100, facts)), None, "{facts:?}");
        }
    }
}
