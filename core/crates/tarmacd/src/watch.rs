//! What wakes the daemon to look at its docs. A wake carries no detail: the
//! daemon compares each doc with its file (`docs::report_changes`), so a
//! change whose wake was lost is reported at the next look, not never.

use std::path::Path;
use std::time::Duration;

/// The burst window docs/protocol.md gives a `file_event`: the watcher wakes
/// the daemon one time for a burst, and `docs::watch_loop` leaves this long
/// between two looks.
pub const BURST: Duration = Duration::from_millis(100);

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{DebounceEventResult, Debouncer, RecommendedCache, new_debouncer};

pub trait WakeSource: Send {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()>;
    fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()>;
}

/// FSEvents through `notify`. Each `watch` and `unwatch` restarts its one
/// stream, and the restart loses the events that the stream has not delivered
/// yet (#253): the caller looks at its docs after either.
pub struct NotifySource(Debouncer<RecommendedWatcher, RecommendedCache>);

impl NotifySource {
    /// `wake` runs on the watcher's thread, one time for each burst of events.
    pub fn new(wake: impl Fn() + Send + 'static) -> anyhow::Result<Self> {
        let debouncer = new_debouncer(BURST, None, move |res: DebounceEventResult| {
            if let Err(errors) = res {
                tracing::warn!("watch errors: {errors:?}");
            }
            wake();
        })?;
        Ok(NotifySource(debouncer))
    }
}

impl WakeSource for NotifySource {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
        Ok(self.0.watch(dir, RecursiveMode::NonRecursive)?)
    }

    fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()> {
        Ok(self.0.unwatch(dir)?)
    }
}
