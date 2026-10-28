//! What wakes the daemon to look at its docs. A wake carries no detail: the
//! daemon compares each doc with its file (`docs::report_changes`), so a
//! change whose wake was lost is reported at the next look, not never.

use std::path::Path;
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

/// The burst window docs/protocol.md gives a `file_event`: how long
/// `docs::watch_loop` waits after a wake before it looks, and so the least
/// time between two of its looks.
pub const BURST: Duration = Duration::from_millis(100);

pub trait WakeSource: Send {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()>;
    fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()>;
}

/// FSEvents through `notify`. Each `watch` and `unwatch` restarts its one
/// stream, and the restart loses the events that the stream has not delivered
/// yet (#253): the caller looks at its docs after either. No debouncer (#258).
pub struct NotifySource(RecommendedWatcher);

impl NotifySource {
    /// `wake` runs on the watcher's thread, for each event.
    pub fn new(wake: impl Fn() + Send + 'static) -> anyhow::Result<Self> {
        let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Err(error) = res {
                tracing::warn!("watch error: {error:?}");
            }
            wake();
        })?;
        Ok(NotifySource(watcher))
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
