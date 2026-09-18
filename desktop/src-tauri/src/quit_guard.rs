//! Every decision the ⌘Q guard makes (spec 2609.0016, issue #171).
//!
//! No AppKit types cross this line: the event's raw modifier bits, the Quit
//! item's live key equivalent, the clock and the key state are all passed in.
//! That is what leaves `quit_intercept.rs` as wiring — and what makes the hold
//! threshold, the second-tap window and the keyboard-Quit test testable at all,
//! since none of them can be driven from a synthetic event (`tarmac dev key`
//! dispatches DOM events, which never reach AppKit).

/// How long Q must be held before the gesture is committed. Chromium's
/// `kShowDuration` 1.5 s minus its 1.0 s fuzz (`confirm_quit_panel_controller.mm`).
pub const HOLD_MS: u64 = 500;
/// A second ⌘Q this soon after the PREVIOUS PRESS quits, as in Chromium.
pub const SECOND_TAP_MS: u64 = 1_000;
/// How stale `[NSApp currentEvent]` may be and still count as the keypress that
/// triggered the item. It must outlast a busy web process's round trip
/// (constraint 7 of the design), because WebKit only re-sends the keyDown to
/// the menu after the page has left it unhandled.
pub const FRESHNESS_BOUND_MS: i64 = 2_000;
/// Key-state sampling period. Q's keyUp never arrives while ⌘ is held.
pub const POLL_MS: u64 = 50;
/// How long the notice stays up after an early release, and its fade.
pub const LINGER_MS: u64 = 1_000;
pub const FADE_MS: u64 = 200;

// NSEventModifierFlags raw bits, restated so this module needs no AppKit.
const SHIFT: u64 = 1 << 17;
const CONTROL: u64 = 1 << 18;
const OPTION: u64 = 1 << 19;
const COMMAND: u64 = 1 << 20;

/// The only bits a shortcut match may consider. Caps Lock, Fn, NumericPad and
/// Help ride along on a perfectly ordinary ⌘Q and must never break it.
const MATCHED: u64 = SHIFT | CONTROL | OPTION | COMMAND;

#[derive(Debug, Clone, PartialEq)]
pub enum Phase {
    Idle { last_start_ms: Option<u64> },
    Showing { started_ms: u64 },
    /// `since_ms` records when the gesture committed, for the tests' view of
    /// the state table; no decision reads it.
    Confirming { since_ms: u64 },
}

#[derive(Debug, PartialEq)]
pub enum Route {
    TerminateNow,
    Guard,
}

#[derive(Debug, PartialEq)]
pub enum Effect {
    ShowHud,
    LingerThenFadeHud,
    /// Hides the cockpit AND cancels any pending linger or fade: past the
    /// threshold the notice stays up over the hidden window until the app
    /// exits, and a second tap inherits the first tap's notice.
    HideWindows,
    StartPolling(u16),
    StopPolling,
    Exit,
}

/// What the handler read off `[NSApp currentEvent]` and the Quit item that
/// invoked it.
pub struct QuitEvent {
    pub is_key_down: bool,
    pub modifiers: u64,
    pub item_mask: u64,
    pub item_key_equivalent: String,
    pub age_ms: i64,
}

pub struct QuitGuard {
    phase: Phase,
    /// The last keyDown timestamp that drove the machine. WebKit can re-send
    /// the same `NSEvent` object, and a second delivery must not advance the
    /// gesture.
    last_press_ms: Option<u64>,
}

impl Default for QuitGuard {
    fn default() -> Self {
        Self { phase: Phase::Idle { last_start_ms: None }, last_press_ms: None }
    }
}

impl QuitGuard {
    /// The wiring acts on the effects, never on the phase; the tests read it to
    /// pin the transitions the table promises.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn phase(&self) -> &Phase {
        &self.phase
    }

    /// Guard iff this really is the Quit KEYPRESS and either a gesture is
    /// already running or the toggle is on. Everything else — a menu click, a
    /// stale `currentEvent`, someone else's chord — quits at once.
    pub fn route(&self, ev: &QuitEvent, enabled: bool) -> Route {
        let idle = matches!(self.phase, Phase::Idle { .. });
        if is_keyboard_quit(ev) && (!idle || enabled) {
            Route::Guard
        } else {
            Route::TerminateNow
        }
    }

    /// A keyDown delivered to the retargeted Quit item. `press_ms` is the
    /// event's own timestamp, so the hold and the second-tap window count from
    /// the physical press rather than from the handler, which WebKit can reach
    /// a whole web-process round trip later.
    pub fn on_quit_key(&mut self, press_ms: u64, key_code: u16, is_repeat: bool) -> Vec<Effect> {
        if is_repeat || self.last_press_ms == Some(press_ms) {
            return Vec::new();
        }
        self.last_press_ms = Some(press_ms);
        match self.phase {
            Phase::Idle { last_start_ms } => {
                let recent = last_start_ms
                    .and_then(|start| press_ms.checked_sub(start))
                    .is_some_and(|since| since < SECOND_TAP_MS);
                if recent {
                    self.phase = Phase::Confirming { since_ms: press_ms };
                    vec![Effect::HideWindows, Effect::StartPolling(key_code)]
                } else {
                    self.phase = Phase::Showing { started_ms: press_ms };
                    vec![Effect::ShowHud, Effect::StartPolling(key_code)]
                }
            }
            // Re-pressed before a poll saw the release: a second tap. No
            // `StartPolling` — the poller is already running on the first
            // chord's key, which is the key still physically down.
            Phase::Showing { .. } => {
                self.phase = Phase::Confirming { since_ms: press_ms };
                vec![Effect::HideWindows]
            }
            Phase::Confirming { .. } => Vec::new(),
        }
    }

    /// One key-state sample. The wiring takes it on the main thread and stops
    /// polling the moment `StopPolling` is applied, so a sample always belongs
    /// to the phase it lands in — and, since `route` never guards a press from
    /// the future, it is never older than the press that started the gesture.
    pub fn on_poll(&mut self, sampled_ms: u64, key_down: bool) -> Vec<Effect> {
        match self.phase {
            Phase::Idle { .. } => Vec::new(),
            Phase::Showing { started_ms } => {
                if !key_down {
                    self.phase = Phase::Idle { last_start_ms: Some(started_ms) };
                    return vec![Effect::LingerThenFadeHud, Effect::StopPolling];
                }
                if sampled_ms.saturating_sub(started_ms) < HOLD_MS {
                    return Vec::new();
                }
                self.phase = Phase::Confirming { since_ms: sampled_ms };
                vec![Effect::HideWindows]
            }
            Phase::Confirming { .. } => {
                if key_down {
                    return Vec::new();
                }
                self.phase = Phase::Idle { last_start_ms: None };
                vec![Effect::StopPolling, Effect::Exit]
            }
        }
    }
}

/// Whether the event that invoked the Quit item is the keypress for its
/// shortcut. AppKit already decided that the chord matches; this only rules out
/// the events that reach the item some other way — a mouse click, keyboard menu
/// navigation's Return, a VoiceOver press whose `currentEvent` is older.
fn is_keyboard_quit(ev: &QuitEvent) -> bool {
    ev.is_key_down
        && !ev.item_key_equivalent.is_empty()
        && (ev.modifiers & MATCHED) == expected_modifiers(&ev.item_key_equivalent, ev.item_mask)
        && (0..=FRESHNESS_BOUND_MS).contains(&ev.age_ms)
}

/// The chord the item carries. A remap can put Shift in the key equivalent's
/// character instead of the mask (Chromium `nsmenuitem_additions.mm`).
fn expected_modifiers(key_equivalent: &str, mask: u64) -> u64 {
    let mut wanted = mask & MATCHED;
    if carries_shift(key_equivalent) {
        wanted |= SHIFT;
    }
    wanted
}

fn carries_shift(key_equivalent: &str) -> bool {
    let mut chars = key_equivalent.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => c.to_lowercase().next() != Some(c),
        _ => false,
    }
}

/// The shortcut as the menu bar prints it.
pub fn shortcut_label(key_equivalent: &str, mask: u64) -> String {
    let wanted = expected_modifiers(key_equivalent, mask);
    let mut label = String::new();
    for (bit, glyph) in [(CONTROL, '⌃'), (OPTION, '⌥'), (SHIFT, '⇧'), (COMMAND, '⌘')] {
        if wanted & bit != 0 {
            label.push(glyph);
        }
    }
    label.extend(key_equivalent.chars().flat_map(char::to_uppercase));
    label
}

pub fn notice_text(key_equivalent: &str, mask: u64) -> String {
    format!("Hold {} to Quit", shortcut_label(key_equivalent, mask))
}

/// `NSEvent.timestamp` (seconds since boot) as whole milliseconds. A zero,
/// negative or NaN timestamp saturates to 0, which the freshness check then
/// rejects as ancient — both are seen in the field.
pub fn press_ms(timestamp_s: f64) -> u64 {
    (timestamp_s * 1000.0) as u64
}

/// The event's age. Signed, because a bogus timestamp from the future is a
/// thing that happens in the field and a `u64` subtraction would panic on it.
pub fn age_ms(now_ms: u64, press_ms: u64) -> i64 {
    now_ms as i64 - press_ms as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A keyboard ⌘Q against the default Quit item, fresh.
    fn cmd_q() -> QuitEvent {
        QuitEvent {
            is_key_down: true,
            modifiers: COMMAND,
            item_mask: COMMAND,
            item_key_equivalent: "q".into(),
            age_ms: 0,
        }
    }

    /// S1 — the keypress the whole feature exists for.
    #[test]
    fn a_fresh_keyboard_quit_is_guarded() {
        assert_eq!(QuitGuard::default().route(&cmd_q(), true), Route::Guard);
    }

    /// S2 — a menu click carries a mouse event, and a gesture in progress must
    /// not turn one into a guarded quit either.
    #[test]
    fn a_non_key_event_terminates_even_mid_gesture() {
        let click = QuitEvent { is_key_down: false, ..cmd_q() };
        let mut guard = QuitGuard::default();
        assert_eq!(guard.route(&click, true), Route::TerminateNow);

        guard.on_quit_key(10_000, 12, false);
        assert_eq!(guard.route(&click, true), Route::TerminateNow);
        let other_chord = QuitEvent { modifiers: OPTION | COMMAND, ..cmd_q() };
        assert_eq!(guard.route(&other_chord, true), Route::TerminateNow);
    }

    /// S3 — keyboard menu navigation ends in a bare Return, and a chord the
    /// item does not carry is somebody else's shortcut.
    #[test]
    fn a_keydown_whose_modifiers_differ_from_the_item_terminates() {
        let guard = QuitGuard::default();
        assert_eq!(guard.route(&QuitEvent { modifiers: 0, ..cmd_q() }, true), Route::TerminateNow);
        assert_eq!(
            guard.route(&QuitEvent { modifiers: OPTION | COMMAND, ..cmd_q() }, true),
            Route::TerminateNow
        );
    }

    /// S4 — Caps Lock, Fn, NumericPad and Help are not part of a shortcut.
    #[test]
    fn modifier_bits_outside_the_shortcut_never_break_a_match() {
        let guard = QuitGuard::default();
        for extra in [1 << 16, 1 << 23, 1 << 21, 1 << 22] {
            let ev = QuitEvent { modifiers: COMMAND | extra, ..cmd_q() };
            assert_eq!(guard.route(&ev, true), Route::Guard, "extra bit {extra:#x}");
        }
    }

    /// S5 — a remap can store Shift in the key equivalent's character
    /// (Chromium `nsmenuitem_additions.mm`), in the mask, or in both.
    #[test]
    fn an_uppercase_key_equivalent_implies_shift() {
        let guard = QuitGuard::default();
        let upper = QuitEvent { item_key_equivalent: "Q".into(), ..cmd_q() };
        assert_eq!(
            guard.route(&QuitEvent { modifiers: SHIFT | COMMAND, ..upper }, true),
            Route::Guard
        );
        let upper = QuitEvent { item_key_equivalent: "Q".into(), ..cmd_q() };
        assert_eq!(guard.route(&upper, true), Route::TerminateNow);
        let both = QuitEvent {
            item_key_equivalent: "Q".into(),
            item_mask: SHIFT | COMMAND,
            modifiers: SHIFT | COMMAND,
            ..cmd_q()
        };
        assert_eq!(guard.route(&both, true), Route::Guard);
    }

    /// S6 — the item's live mask is the shortcut, so a user remap is guarded
    /// and the stock chord is not.
    #[test]
    fn a_remapped_item_guards_its_own_chord_only() {
        let guard = QuitGuard::default();
        let remapped = QuitEvent { item_mask: OPTION | COMMAND, ..cmd_q() };
        assert_eq!(
            guard.route(&QuitEvent { modifiers: OPTION | COMMAND, ..remapped }, true),
            Route::Guard
        );
        let remapped = QuitEvent { item_mask: OPTION | COMMAND, ..cmd_q() };
        assert_eq!(guard.route(&remapped, true), Route::TerminateNow);
    }

    /// S7 — `currentEvent` is only trusted while it is fresh. A failed check
    /// costs an unguarded quit, never a stuck one.
    #[test]
    fn a_stale_or_impossible_timestamp_terminates() {
        let guard = QuitGuard::default();
        // Literal, not `FRESHNESS_BOUND_MS ± 1`: the point of the test is the
        // bound's value, and an expectation recomputed from the constant would
        // survive any change to it.
        for (age, want) in [
            (2_000, Route::Guard),
            (2_001, Route::TerminateNow),
            (-1, Route::TerminateNow),
            (28_000_000, Route::TerminateNow),
        ] {
            assert_eq!(guard.route(&QuitEvent { age_ms: age, ..cmd_q() }, true), want, "age {age}");
        }
    }

    /// S8 — the toggle only decides whether a gesture STARTS. One already
    /// running stays guarded, or a mid-gesture flip would quit on the spot.
    #[test]
    fn the_toggle_off_terminates_only_from_idle() {
        let mut guard = QuitGuard::default();
        assert_eq!(guard.route(&cmd_q(), false), Route::TerminateNow);

        guard.on_quit_key(10_000, 12, false);
        assert_eq!(guard.route(&cmd_q(), false), Route::Guard);
        guard.on_poll(10_500, true);
        assert_eq!(guard.route(&cmd_q(), false), Route::Guard);
    }

    /// S23 — an item with no shortcut cannot have been triggered by a key, so
    /// whatever `currentEvent` holds is somebody else's.
    #[test]
    fn an_item_without_a_key_equivalent_is_never_a_keyboard_quit() {
        let guard = QuitGuard::default();
        let no_shortcut = QuitEvent { item_key_equivalent: String::new(), ..cmd_q() };
        assert_eq!(guard.route(&no_shortcut, true), Route::TerminateNow);
    }

    /// The item's own mask is masked too: a stray bit in it must not become
    /// part of the chord the handler demands.
    #[test]
    fn a_bit_outside_the_shortcut_in_the_items_mask_is_ignored() {
        let guard = QuitGuard::default();
        let noisy_item = QuitEvent { item_mask: COMMAND | (1 << 16), ..cmd_q() };
        assert_eq!(guard.route(&noisy_item, true), Route::Guard);
    }

    /// Only a single-character key equivalent can carry Shift in its character.
    /// A function-key equivalent must not have ⇧ invented for it.
    #[test]
    fn a_multi_character_key_equivalent_never_implies_shift() {
        let guard = QuitGuard::default();
        let arrow = QuitEvent { item_key_equivalent: "UpArrow".into(), ..cmd_q() };
        assert_eq!(guard.route(&arrow, true), Route::Guard);
    }

    /// S22 — the notice names the shortcut AppKit actually matched.
    #[test]
    fn the_shortcut_label_reads_in_apples_order() {
        assert_eq!(shortcut_label("q", COMMAND), "⌘Q");
        assert_eq!(shortcut_label("q", OPTION | COMMAND), "⌥⌘Q");
        assert_eq!(shortcut_label("Q", COMMAND), "⇧⌘Q");
        assert_eq!(shortcut_label("Q", SHIFT | COMMAND), "⇧⌘Q");
        assert_eq!(shortcut_label("q", CONTROL | OPTION | SHIFT | COMMAND), "⌃⌥⇧⌘Q");
        assert_eq!(shortcut_label(".", COMMAND), "⌘.");
    }

    /// S22 — and the sentence around it.
    #[test]
    fn the_notice_names_the_live_shortcut() {
        assert_eq!(notice_text("q", COMMAND), "Hold ⌘Q to Quit");
        assert_eq!(notice_text("q", OPTION | COMMAND), "Hold ⌥⌘Q to Quit");
    }

    /// A guard showing the notice from a tap at `press`.
    fn showing(press: u64) -> QuitGuard {
        let mut guard = QuitGuard::default();
        guard.on_quit_key(press, 12, false);
        guard
    }

    /// A guard back in `Idle` after a completed tap: pressed at `press`,
    /// released by the poll at `release`.
    fn tapped(press: u64, release: u64) -> QuitGuard {
        let mut guard = showing(press);
        guard.on_poll(release, false);
        guard
    }

    /// S10 — the notice goes up and the poller follows the key that was
    /// pressed, never a hard-coded Q.
    #[test]
    fn a_first_tap_shows_the_notice_and_polls_the_pressed_key() {
        let mut guard = QuitGuard::default();
        assert_eq!(guard.on_quit_key(10_000, 12, false), vec![Effect::ShowHud, Effect::StartPolling(12)]);
        assert_eq!(*guard.phase(), Phase::Showing { started_ms: 10_000 });

        let mut remapped = QuitGuard::default();
        assert_eq!(remapped.on_quit_key(10_000, 13, false), vec![Effect::ShowHud, Effect::StartPolling(13)]);
        assert_eq!(*remapped.phase(), Phase::Showing { started_ms: 10_000 });
    }

    /// S11 — released before the threshold: the notice lingers, nothing quits.
    #[test]
    fn a_release_before_the_hold_threshold_is_a_tap() {
        let mut guard = showing(10_000);
        assert_eq!(guard.on_poll(10_499, true), vec![]);
        assert_eq!(*guard.phase(), Phase::Showing { started_ms: 10_000 });

        assert_eq!(
            guard.on_poll(10_120, false),
            vec![Effect::LingerThenFadeHud, Effect::StopPolling]
        );
        assert_eq!(*guard.phase(), Phase::Idle { last_start_ms: Some(10_000) });
    }

    /// S12 — past the threshold the windows go, and the app exits only once Q
    /// is up: quitting mid-hold would send the repeats to the next app.
    #[test]
    fn a_hold_hides_the_windows_and_exits_on_release() {
        let mut guard = showing(10_000);
        assert_eq!(guard.on_poll(10_500, true), vec![Effect::HideWindows]);
        assert_eq!(*guard.phase(), Phase::Confirming { since_ms: 10_500 });

        assert_eq!(guard.on_poll(10_550, true), vec![]);
        assert_eq!(*guard.phase(), Phase::Confirming { since_ms: 10_500 });

        assert_eq!(guard.on_poll(10_600, false), vec![Effect::StopPolling, Effect::Exit]);
        assert_eq!(*guard.phase(), Phase::Idle { last_start_ms: None });
    }

    /// S13 — the first sample can arrive late (WebKit's round trip, or a
    /// stalled poller). What it reads is what happened, not how long it took.
    #[test]
    fn the_first_poll_decides_on_what_it_reads_however_late_it_is() {
        let mut released = showing(10_000);
        assert_eq!(
            released.on_poll(10_700, false),
            vec![Effect::LingerThenFadeHud, Effect::StopPolling]
        );
        assert_eq!(*released.phase(), Phase::Idle { last_start_ms: Some(10_000) });

        let mut held = showing(10_000);
        assert_eq!(held.on_poll(10_700, true), vec![Effect::HideWindows]);
        assert_eq!(*held.phase(), Phase::Confirming { since_ms: 10_700 });
    }

    /// S14 — Chromium's second tap, measured from the first PRESS.
    #[test]
    fn a_second_tap_within_the_window_commits_the_quit() {
        let mut guard = tapped(0, 400);
        assert_eq!(
            guard.on_quit_key(950, 12, false),
            vec![Effect::HideWindows, Effect::StartPolling(12)]
        );
        assert_eq!(*guard.phase(), Phase::Confirming { since_ms: 950 });

        assert_eq!(guard.on_poll(1_000, false), vec![Effect::StopPolling, Effect::Exit]);
        assert_eq!(*guard.phase(), Phase::Idle { last_start_ms: None });
    }

    /// S15/S21 — the window is a strict 1 s from the previous press, not from
    /// its release.
    #[test]
    fn the_second_tap_window_closes_one_second_after_the_previous_press() {
        for press in [1_000, 1_050] {
            let mut guard = tapped(0, 400);
            assert_eq!(
                guard.on_quit_key(press, 12, false),
                vec![Effect::ShowHud, Effect::StartPolling(12)],
                "press at {press}"
            );
            assert_eq!(*guard.phase(), Phase::Showing { started_ms: press });
        }

        let mut guard = tapped(0, 400);
        assert_eq!(
            guard.on_quit_key(999, 12, false),
            vec![Effect::HideWindows, Effect::StartPolling(12)]
        );
        assert_eq!(*guard.phase(), Phase::Confirming { since_ms: 999 });
    }

    /// S21 — a press older than the last start (a clock that went backwards,
    /// or an out-of-order delivery) is simply not recent.
    #[test]
    fn a_press_older_than_the_last_start_is_not_a_second_tap() {
        let mut guard = tapped(1_000, 1_100);
        assert_eq!(guard.on_quit_key(900, 12, false), vec![Effect::ShowHud, Effect::StartPolling(12)]);
        assert_eq!(*guard.phase(), Phase::Showing { started_ms: 900 });
    }

    /// S16 — Q was re-pressed before a poll saw the release, so this is a
    /// second tap by another name. The poller is already running on the first
    /// chord's key, and keeps it.
    #[test]
    fn a_re_press_while_the_notice_shows_commits_without_a_second_poller() {
        let mut guard = showing(10_000);
        assert_eq!(guard.on_quit_key(10_300, 13, false), vec![Effect::HideWindows]);
        assert_eq!(*guard.phase(), Phase::Confirming { since_ms: 10_300 });
    }

    /// S17 — once committed, another chord changes nothing.
    #[test]
    fn a_re_press_while_confirming_does_nothing() {
        let mut guard = showing(10_000);
        guard.on_poll(10_500, true);
        assert_eq!(guard.on_quit_key(10_700, 12, false), vec![]);
        assert_eq!(*guard.phase(), Phase::Confirming { since_ms: 10_500 });
    }

    /// S18 — auto-repeat reaches the retargeted item too, and must never
    /// advance the gesture.
    #[test]
    fn auto_repeats_are_ignored_in_every_phase() {
        let mut idle = tapped(10_000, 10_120);
        assert_eq!(idle.on_quit_key(10_200, 12, true), vec![]);
        assert_eq!(*idle.phase(), Phase::Idle { last_start_ms: Some(10_000) });

        let mut notice = showing(10_000);
        assert_eq!(notice.on_quit_key(10_100, 12, true), vec![]);
        assert_eq!(*notice.phase(), Phase::Showing { started_ms: 10_000 });

        let mut confirming = showing(10_000);
        confirming.on_poll(10_500, true);
        assert_eq!(confirming.on_quit_key(10_560, 12, true), vec![]);
        assert_eq!(*confirming.phase(), Phase::Confirming { since_ms: 10_500 });
    }

    /// S18 — if key state is unreadable the first sample reads "up", so the
    /// hold ends as a tap and the auto-repeats that follow cannot confirm it.
    /// A real second tap still can.
    #[test]
    fn a_hold_whose_first_poll_reads_up_ends_as_a_tap_that_repeats_cannot_confirm() {
        let mut guard = tapped(0, 50);
        // Inside the second-tap window, so `is_repeat` is the only thing
        // standing between this press and Confirming.
        assert_eq!(guard.on_quit_key(500, 12, true), vec![]);
        assert_eq!(*guard.phase(), Phase::Idle { last_start_ms: Some(0) });

        let mut second = tapped(0, 50);
        assert_eq!(second.on_quit_key(500, 12, true), vec![]);
        assert_eq!(
            second.on_quit_key(900, 12, false),
            vec![Effect::HideWindows, Effect::StartPolling(12)]
        );
        assert_eq!(*second.phase(), Phase::Confirming { since_ms: 900 });
    }

    /// S20 — WebKit re-sends the original `NSEvent`, so the same press can
    /// arrive twice. Treating the second as a new chord would turn a tap into a
    /// quit.
    #[test]
    fn the_same_keydown_delivered_twice_advances_nothing() {
        let mut guard = showing(10_000);
        assert_eq!(guard.on_quit_key(10_000, 12, false), vec![]);
        assert_eq!(*guard.phase(), Phase::Showing { started_ms: 10_000 });

        let mut after_tap = tapped(10_000, 10_120);
        assert_eq!(after_tap.on_quit_key(10_000, 12, false), vec![]);
        assert_eq!(*after_tap.phase(), Phase::Idle { last_start_ms: Some(10_000) });

        let mut with_repeat = showing(10_000);
        assert_eq!(with_repeat.on_quit_key(10_100, 12, true), vec![]);
        assert_eq!(with_repeat.on_quit_key(10_000, 12, false), vec![]);
        assert_eq!(*with_repeat.phase(), Phase::Showing { started_ms: 10_000 });
    }

    /// S38 — the wiring never subtracts `u64`s itself: a future timestamp is a
    /// negative age, and a zero one is ancient.
    #[test]
    fn an_events_age_is_signed_and_its_timestamp_is_whole_milliseconds() {
        assert_eq!(age_ms(1_000, 1_001), -1);
        assert_eq!(age_ms(1_001, 1_000), 1);
        assert_eq!(age_ms(28_000_000, press_ms(0.0)), 28_000_000);
        assert_eq!(press_ms(12.3456), 12_345);
        assert_eq!(press_ms(0.0), 0);
        assert_eq!(press_ms(-1.0), 0);
    }
}
