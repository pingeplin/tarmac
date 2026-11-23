// Shared integration harness: a real daemon process on a temp socket + state
// file, with app/cli clients speaking the wire protocol over std sockets.
#![allow(dead_code)] // each test binary uses a different slice of the harness

mod conn;
mod daemon;
mod frames;
mod fs;
mod state;

#[allow(unused_imports)]
pub(crate) use conn::*;
#[allow(unused_imports)]
pub(crate) use daemon::*;
#[allow(unused_imports)]
pub(crate) use frames::*;
#[allow(unused_imports)]
pub(crate) use fs::*;
#[allow(unused_imports)]
pub(crate) use state::*;

use std::time::Duration;

pub(crate) const LONG: Duration = Duration::from_secs(20);

/// A job-control shell that reads no rc file: each command runs in a process
/// group of its own, so the foreground leader changes.
pub(crate) const JOB_SHELL: &[&str] = &["/bin/zsh", "-f", "-i"];

/// Three times the daemon's 150 ms save debounce: a save that is due has
/// landed by its end.
pub(crate) const SAVE_WINDOW: Duration = Duration::from_millis(450);
