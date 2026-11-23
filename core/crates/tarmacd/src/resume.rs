//! A terminal's resume command (spec 2611.0011): the handle's flag that lets
//! a poll tick or a key with no command take no lock. Pure. The command lives
//! in the board's `term_records`; its holder (`holder::tie`) on the terminal's
//! handle, in memory only.

/// The handle's flag: no command, a command with a holder, or one with none
/// (moved to this terminal by `succeeds`, as a command loaded from disk is),
/// which typed input drops.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum Flag {
    None = 0,
    Held = 1,
    Unclaimed = 2,
}

impl Flag {
    pub(crate) fn from_u8(raw: u8) -> Flag {
        match raw {
            1 => Flag::Held,
            2 => Flag::Unclaimed,
            _ => Flag::None,
        }
    }
}
