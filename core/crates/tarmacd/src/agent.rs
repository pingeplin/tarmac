//! Which process a terminal's report belongs to: the walk from the reporting
//! client up its parent pids to the terminal's PTY child. Pure: the parent
//! read is injected.

pub type Pid = libc::pid_t;

/// The longest chain the walk follows, a guard against a cycle.
const MAX_HOPS: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Found {
    Agent(Pid),
    /// The caller is the shell, or a child of it: a report typed at the prompt.
    Shell,
    Unattributed,
}

/// `caller` is the client's pid, `child` the PTY child's, `child_is_cmd` true
/// when the terminal was spawned with a `cmd`. The caller is never the agent
/// itself: the cli exits right after its answer.
pub fn find_agent(
    caller: Option<Pid>,
    child: Option<Pid>,
    child_is_cmd: bool,
    parent_of: impl Fn(Pid) -> Option<Pid>,
) -> Found {
    let (Some(caller), Some(child)) = (caller, child) else { return Found::Unattributed };
    let mut chain = vec![caller];
    let mut pid = caller;
    while pid != child {
        if pid <= 1 || chain.len() > MAX_HOPS {
            return Found::Unattributed;
        }
        let Some(parent) = parent_of(pid) else { return Found::Unattributed };
        chain.push(parent);
        pid = parent;
    }
    match chain.len() {
        _ if child_is_cmd => Found::Agent(child),
        1 | 2 => Found::Shell,
        n => Found::Agent(chain[n - 2]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const CHILD: Pid = 100;
    const A: Pid = 200;
    const X: Pid = 300;
    const Y: Pid = 400;
    const CALLER: Pid = 500;

    fn walk(caller: Pid, cmd: bool, parents: &[(Pid, Pid)]) -> Found {
        let table: HashMap<Pid, Pid> = parents.iter().copied().collect();
        find_agent(Some(caller), Some(CHILD), cmd, |pid| table.get(&pid).copied())
    }

    const CHAIN: &[(Pid, Pid)] = &[(CALLER, X), (X, A), (A, CHILD), (CHILD, 1)];

    #[test]
    fn the_agent_is_the_member_just_below_the_shell() {
        assert_eq!(walk(CALLER, false, CHAIN), Found::Agent(A));
    }

    #[test]
    fn a_caller_whose_parent_is_the_shell_is_held_by_the_shell() {
        assert_eq!(walk(CALLER, false, &[(CALLER, CHILD), (CHILD, 1)]), Found::Shell);
    }

    #[test]
    fn the_shell_itself_as_the_caller_is_held_by_the_shell() {
        assert_eq!(walk(CHILD, false, &[(CHILD, 1)]), Found::Shell);
    }

    #[test]
    fn a_child_spawned_as_cmd_is_the_agent_for_every_caller() {
        assert_eq!(walk(CALLER, true, CHAIN), Found::Agent(CHILD));
        assert_eq!(walk(CALLER, true, &[(CALLER, CHILD), (CHILD, 1)]), Found::Agent(CHILD));
    }

    #[test]
    fn a_caller_re_parented_to_launchd_is_unattributed() {
        // A parent of pid 1 that leads to the child: only the guard stops there.
        assert_eq!(walk(CALLER, false, &[(CALLER, X), (X, 1), (1, CHILD)]), Found::Unattributed);
    }

    #[test]
    fn a_parent_that_cannot_be_read_leaves_the_caller_unattributed() {
        assert_eq!(walk(CALLER, false, &[(CALLER, X)]), Found::Unattributed);
    }

    #[test]
    fn no_caller_or_no_child_is_unattributed() {
        let table: HashMap<Pid, Pid> = CHAIN.iter().copied().collect();
        let parent_of = |pid| table.get(&pid).copied();
        assert_eq!(find_agent(None, Some(CHILD), false, parent_of), Found::Unattributed);
        assert_eq!(find_agent(Some(CALLER), None, false, parent_of), Found::Unattributed);
    }

    #[test]
    fn a_cycle_ends_the_walk_unattributed() {
        assert_eq!(walk(CALLER, false, &[(CALLER, X), (X, Y), (Y, X)]), Found::Unattributed);
    }
}
