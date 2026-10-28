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
/// yet (#253): the caller looks at its docs after either.
///
/// No debouncer: notify-debouncer-full 0.7 gives a path's events only after
/// they stop for its timeout, so a file written with shorter gaps woke the
/// daemon only when the writes stopped (#258). `docs::watch_loop` spaces the
/// looks instead.
pub struct NotifySource<W: Watcher = RecommendedWatcher>(W);

impl NotifySource {
    /// `wake` runs on the watcher's thread, for each event.
    pub fn new(wake: impl Fn() + Send + 'static) -> anyhow::Result<Self> {
        Self::on(wake)
    }
}

impl<W: Watcher> NotifySource<W> {
    fn on(wake: impl Fn() + Send + 'static) -> anyhow::Result<Self> {
        let handler = move |res: notify::Result<notify::Event>| {
            if let Err(error) = res {
                tracing::warn!("watch error: {error:?}");
            }
            wake();
        };
        Ok(NotifySource(W::new(handler, notify::Config::default())?))
    }
}

impl<W: Watcher + Send> WakeSource for NotifySource<W> {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
        Ok(self.0.watch(dir, RecursiveMode::NonRecursive)?)
    }

    fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()> {
        Ok(self.0.unwatch(dir)?)
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    use notify::event::{DataChange, ModifyKind};
    use notify::{Event, EventHandler, EventKind, WatcherKind};

    use super::*;

    static HANDLER: Mutex<Option<Box<dyn EventHandler>>> = Mutex::new(None);

    /// A watcher whose events the test gives by hand, through `HANDLER`.
    struct ByHand;

    impl Watcher for ByHand {
        fn new<F: EventHandler>(handler: F, _: notify::Config) -> notify::Result<Self> {
            *HANDLER.lock().unwrap() = Some(Box::new(handler));
            Ok(ByHand)
        }
        fn watch(&mut self, _: &Path, _: RecursiveMode) -> notify::Result<()> {
            Ok(())
        }
        fn unwatch(&mut self, _: &Path) -> notify::Result<()> {
            Ok(())
        }
        fn kind() -> WatcherKind {
            WatcherKind::NullWatcher
        }
    }

    // #258: a file written with gaps shorter than BURST must still wake the
    // daemon while the writes go on; `docs::watch_loop` keeps the looks apart.
    #[test]
    fn each_event_wakes_while_a_file_keeps_changing() {
        let wakes = Arc::new(AtomicUsize::new(0));
        let _source = NotifySource::<ByHand>::on({
            let wakes = wakes.clone();
            move || {
                wakes.fetch_add(1, Ordering::SeqCst);
            }
        })
        .unwrap();
        let mut handler = HANDLER.lock().unwrap().take().unwrap();

        let events = 50;
        for _ in 0..events {
            let changed = Event::new(EventKind::Modify(ModifyKind::Data(DataChange::Content)))
                .add_path(PathBuf::from("/docs/y.md"));
            handler.handle_event(Ok(changed));
        }
        assert_eq!(wakes.load(Ordering::SeqCst), events, "each event wakes");
    }
}
