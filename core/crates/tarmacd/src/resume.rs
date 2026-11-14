//! A terminal's resume command (spec 2611.0011): the holder it lasts for, and
//! the handle's flag that lets a poll tick or a key with no command take no
//! lock. Pure. The command lives in the board's `term_records`; the holder
//! beside it, in memory only.

use crate::proc::{Facts, Pid};
use crate::reports::Holder;

/// The handle's flag: no command, a command with a holder, or one with none
/// (loaded from disk, or moved by `succeeds`), which typed input drops.
pub const NONE: u8 = 0;
pub const HELD: u8 = 1;
pub const UNCLAIMED: u8 = 2;

/// The holder of a resume command is always a pid with its start time (D2):
/// a command lasts for a process's life, not until the next foreground job.
/// So the shell itself holds one set at the prompt, and the leader the
/// fallback's. `None` when that process cannot be read.
pub fn tie(holder: Holder, facts_of: impl Fn(Pid) -> Facts) -> Option<Holder> {
    match holder {
        Holder::Agent { .. } => Some(holder),
        Holder::Shell { pid, .. } | Holder::Leader { pid } => match facts_of(pid) {
            Facts::Live { started, .. } => Some(Holder::Agent { pid, started }),
            Facts::Gone | Facts::Unread => None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(pid: Pid, facts: Facts) -> impl Fn(Pid) -> Facts {
        move |p| if p == pid { facts } else { Facts::Gone }
    }

    #[test]
    fn an_agent_stays_as_it_is() {
        let agent = Holder::Agent { pid: 200, started: 11 };
        assert_eq!(tie(agent, |_| Facts::Gone), Some(agent));
    }

    #[test]
    fn a_shell_or_a_leader_is_tied_to_its_own_start_time() {
        let facts = table(100, Facts::Live { ppid: 1, started: 7 });
        assert_eq!(tie(Holder::Shell { pid: 100, caller: 500 }, &facts), Some(Holder::Agent { pid: 100, started: 7 }));
        assert_eq!(tie(Holder::Leader { pid: 100 }, &facts), Some(Holder::Agent { pid: 100, started: 7 }));
    }

    #[test]
    fn a_shell_or_a_leader_that_cannot_be_read_ties_nothing() {
        for facts in [Facts::Gone, Facts::Unread] {
            assert_eq!(tie(Holder::Leader { pid: 100 }, table(100, facts)), None, "{facts:?}");
        }
    }
}
