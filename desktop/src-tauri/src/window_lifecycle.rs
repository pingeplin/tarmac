//! Who owes the window a comeback (spec 2609.0016, issue #171).
//!
//! The red button hides the window instead of quitting, so something has to
//! bring it back. Both triggers can fire for one Dock click on an inactive app
//! — `NSApplicationDidBecomeActiveNotification` and `RunEvent::Reopen` — so the
//! restore is handed out once per close, not once per trigger. The guard's own
//! `HideWindows` never sets it: a hidden-then-quitting window must stay hidden.

use std::sync::atomic::{AtomicBool, Ordering};

/// Owns its own synchronisation, so the window event and the two restore
/// triggers share it without either call site spelling a lock.
#[derive(Default)]
pub struct HiddenByClose {
    hidden: AtomicBool,
}

impl HiddenByClose {
    pub fn close_requested(&self) {
        self.hidden.store(true, Ordering::SeqCst);
    }

    /// True once after a close, then false until the next one.
    pub fn take_restore(&self) -> bool {
        self.hidden.swap(false, Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// S27 — activation and `Reopen` both fire for one Dock click.
    #[test]
    fn a_close_is_worth_exactly_one_restore() {
        let state = HiddenByClose::default();
        state.close_requested();
        assert!(state.take_restore());
        assert!(!state.take_restore());

        state.close_requested();
        state.close_requested();
        assert!(state.take_restore());
        assert!(!state.take_restore());

        state.close_requested();
        assert!(state.take_restore());
    }

    /// S27b — nothing was hidden by the red button, so nothing is restored.
    /// The guard's `HideWindows` goes through no call at all.
    #[test]
    fn an_untouched_window_is_never_restored() {
        assert!(!HiddenByClose::default().take_restore());
    }
}
