//! The AppKit half of the ⌘Q guard (spec 2609.0016, issue #171).
//!
//! tao implements no `applicationShouldTerminate:`, and a Tauri menu event
//! arrives a run-loop turn late — too late to tell a keypress from a click, or
//! to see auto-repeat. So the native Quit item is retargeted onto `tarmacQuit:`
//! here: AppKit still decides what the Quit shortcut is (no character is ever
//! compared, so every input source and user remap works), and the handler runs
//! inside the key event with `[NSApp currentEvent]` still set.
//!
//! Everything below is wiring. Each decision belongs to `quit_guard.rs`,
//! `quit_notice.rs`, `window_lifecycle.rs` or `app_prefs.rs`; the manual
//! scenarios that discharge the wiring are in `desktop/qa/hold-to-quit-qa.md`.
//!
//! Two rules this file exists to keep:
//!   - `NSApp.terminate` is called ONLY from inside `tarmacQuit:`. From a tao
//!     callback it would re-enter tao's callback mutex through
//!     `applicationWillTerminate:`. The guard's own exit is `app.exit(0)`.
//!   - Q's keyUp never arrives while ⌘ is held (tao's `sendEvent:` sends those
//!     straight to the key window, and a hidden window is not one), so release
//!     is polled — by a timer on the main run loop, which `StopPolling`
//!     invalidates on the spot, so no sample outlives the phase that asked.

use std::cell::{Cell, RefCell};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject, NSObjectProtocol};
use objc2::{define_class, msg_send, sel, DefinedClass, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSApplication, NSApplicationDidBecomeActiveNotification, NSEventType, NSMenu, NSMenuItem,
    NSScreen, NSWindow,
};
use objc2_core_graphics::{CGEventSource, CGEventSourceStateID};
use objc2_foundation::{NSNotificationCenter, NSRunLoop, NSRunLoopCommonModes, NSTimer};
use tauri::menu::{CheckMenuItem, Menu, MenuEvent, MenuId};
use tauri::{AppHandle, Manager, Wry};

#[cfg(debug_assertions)]
use crate::dev_press::{matches_item, Chord};
use crate::quit_guard::{self, Effect, QuitEvent, QuitGuard, Route};
use crate::quit_notice::Notice;
use crate::window_lifecycle::HiddenByClose;

/// The app-menu check item. Chromium's wording and default (on).
pub const WARN_BEFORE_QUIT_ID: &str = "warn_before_quit";
const WARN_BEFORE_QUIT_LABEL: &str = "Warn Before Quitting (⌘Q)";
/// Steps in the notice's fade. Ten over 200 ms reads as a fade and needs no
/// Core Animation, whose completion handler would have to be generation-guarded
/// anyway.
const FADE_STEPS: u32 = 10;

/// Is the guard on? One bool, read by the handler and by the dev driver, set by
/// the menu item and at startup from `app-prefs.json`.
pub struct QuitToggle(AtomicBool);

impl QuitToggle {
    pub fn new(enabled: bool) -> Self {
        Self(AtomicBool::new(enabled))
    }
    pub fn get(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
    fn set(&self, enabled: bool) {
        self.0.store(enabled, Ordering::SeqCst);
    }
}

// The retargeted item holds its target WEAKLY, so this must outlive the menu.
// It is also where the guard, the notice, the poll timer and the notice's
// generation counter live: all of it is main-thread-only, and none of it can
// ride a `run_on_main_thread` closure (AppKit objects are not `Send`).
thread_local! {
    static TARGET: RefCell<Option<Retained<QuitTarget>>> = const { RefCell::new(None) };
}

struct QuitIvars {
    app: AppHandle,
    guard: RefCell<QuitGuard>,
    notice: RefCell<Option<Notice>>,
    /// The running poll and the key it samples. The run loop holds the timer,
    /// so dropping it here would not stop it: it is always invalidated.
    poll: RefCell<Option<(Retained<NSTimer>, u16)>>,
    /// Bumped by `ShowHud`, so a linger or fade left over from an earlier tap
    /// cannot take the new notice away.
    hud_gen: Cell<u64>,
    /// `tarmac dev press`'s key-held override: a key code and the time it reads
    /// as held until. The poller ORs it into its physical read (2609.0018).
    #[cfg(debug_assertions)]
    held: Cell<Option<(u16, u64)>>,
    /// What the handler recorded for the most recent keyboard press it saw:
    /// `press_ms`, route, `age_ms`. A menu click leaves it alone.
    #[cfg(debug_assertions)]
    last_press: Cell<Option<(u64, Route, i64)>>,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "TarmacQuitTarget"]
    #[thread_kind = MainThreadOnly]
    #[ivars = QuitIvars]
    struct QuitTarget;

    unsafe impl NSObjectProtocol for QuitTarget {}

    impl QuitTarget {
        #[unsafe(method(tarmacQuit:))]
        fn tarmac_quit(&self, sender: Option<&AnyObject>) {
            self.on_quit(sender);
        }

        #[unsafe(method(tarmacPoll:))]
        fn tarmac_poll(&self, _timer: &NSTimer) {
            self.on_poll();
        }

        #[unsafe(method(appDidBecomeActive:))]
        fn app_did_become_active(&self, _notification: Option<&AnyObject>) {
            restore_window(&self.ivars().app);
        }
    }
);

impl QuitTarget {
    fn new(mtm: MainThreadMarker, app: AppHandle) -> Retained<Self> {
        let this = mtm.alloc().set_ivars(QuitIvars {
            app,
            guard: RefCell::new(QuitGuard::default()),
            notice: RefCell::new(None),
            poll: RefCell::new(None),
            hud_gen: Cell::new(0),
            #[cfg(debug_assertions)]
            held: Cell::new(None),
            #[cfg(debug_assertions)]
            last_press: Cell::new(None),
        });
        unsafe { msg_send![super(this), init] }
    }

    /// The Quit item fired. Route it, then apply what the route decided —
    /// `terminate:` never returns, so the debug line is written first.
    fn on_quit(&self, sender: Option<&AnyObject>) {
        let mtm = MainThreadMarker::from(self);
        let ns_app = NSApplication::sharedApplication(mtm);
        let item = sender.and_then(|s| s.downcast_ref::<NSMenuItem>());
        let (key_equivalent, item_mask) = item.map_or_else(
            || (String::new(), 0),
            |item| {
                (
                    item.keyEquivalent().to_string(),
                    item.keyEquivalentModifierMask().0 as u64,
                )
            },
        );

        let event = ns_app.currentEvent();
        let is_key_down = event.as_ref().is_some_and(|e| e.r#type() == NSEventType::KeyDown);
        // keyCode and isARepeat are only valid on a key event (NSEvent.h).
        let (press_ms, key_code, is_repeat) = match event.as_ref().filter(|_| is_key_down) {
            Some(e) => (quit_guard::press_ms(e.timestamp()), e.keyCode(), e.isARepeat()),
            None => (0, 0, false),
        };
        let ev = QuitEvent {
            is_key_down,
            modifiers: event.as_ref().map_or(0, |e| e.modifierFlags().0 as u64),
            item_mask,
            item_key_equivalent: key_equivalent,
            age_ms: quit_guard::age_ms(now_ms(), press_ms),
        };
        let enabled = self.ivars().app.state::<QuitToggle>().get();
        let route = self.ivars().guard.borrow().route(&ev, enabled);
        log_quit_key(&route, event.as_ref().map(|e| e.r#type().0), is_repeat, &ev, press_ms);
        #[cfg(debug_assertions)]
        if is_key_down {
            self.ivars().last_press.set(Some((press_ms, route, ev.age_ms)));
        }

        match route {
            Route::TerminateNow => ns_app.terminate(None),
            Route::Guard => {
                let effects = self.ivars().guard.borrow_mut().on_quit_key(press_ms, key_code, is_repeat);
                let notice = quit_guard::notice_text(&ev.item_key_equivalent, ev.item_mask);
                self.apply(mtm, effects, Some(&notice));
            }
        }
    }

    fn on_poll(&self) {
        let Some(key_code) = self.ivars().poll.borrow().as_ref().map(|&(_, key)| key) else {
            return;
        };
        let held = CGEventSource::key_state(CGEventSourceStateID::CombinedSessionState, key_code)
            || self.held_override(key_code);
        let effects = self.ivars().guard.borrow_mut().on_poll(now_ms(), held);
        // No notice text to give: only a chord can raise `ShowHud`.
        self.apply(MainThreadMarker::from(self), effects, None);
    }

    #[cfg(debug_assertions)]
    fn held_override(&self, key_code: u16) -> bool {
        self.ivars().held.get().is_some_and(|(key, until)| key == key_code && now_ms() < until)
    }

    #[cfg(not(debug_assertions))]
    fn held_override(&self, _key_code: u16) -> bool {
        false
    }

    fn apply(&self, mtm: MainThreadMarker, effects: Vec<Effect>, notice: Option<&str>) {
        for effect in effects {
            match effect {
                Effect::ShowHud => {
                    if let Some(text) = notice {
                        self.show_notice(mtm, text);
                    }
                }
                Effect::LingerThenFadeHud => self.linger_then_fade(),
                Effect::HideWindows => {
                    // The fade cancellation `Effect::HideWindows` promises.
                    self.ivars().hud_gen.set(self.ivars().hud_gen.get() + 1);
                    if let Some(window) = self.ivars().app.get_webview_window("main") {
                        let _ = window.hide();
                    }
                }
                Effect::StartPolling(key_code) => self.start_polling(key_code),
                Effect::StopPolling => self.stop_polling(),
                Effect::Exit => self.ivars().app.exit(0),
            }
        }
    }

    fn show_notice(&self, mtm: MainThreadMarker, text: &str) {
        self.ivars().hud_gen.set(self.ivars().hud_gen.get() + 1);
        let mut slot = self.ivars().notice.borrow_mut();
        let notice = slot.get_or_insert_with(|| Notice::new(mtm));
        notice.show(mtm, text, notice_screen(mtm, &self.ivars().app));
    }

    /// Chromium's ending: the notice sits for a second, then fades out. It is
    /// the only thing that takes the notice away — on the hold path it stays up
    /// over the hidden window until the app exits.
    fn linger_then_fade(&self) {
        let generation = self.ivars().hud_gen.get();
        let app = self.ivars().app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(quit_guard::LINGER_MS));
            let step_ms = quit_guard::FADE_MS / u64::from(FADE_STEPS);
            for step in 1..=FADE_STEPS {
                let alpha = 1.0 - f64::from(step) / f64::from(FADE_STEPS);
                if on_main(&app, move |target| target.fade_step(generation, alpha)).is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(step_ms));
            }
            let _ = on_main(&app, move |target| target.hide_notice(generation));
        });
    }

    fn fade_step(&self, generation: u64, alpha: f64) {
        if self.ivars().hud_gen.get() != generation {
            return;
        }
        if let Some(notice) = self.ivars().notice.borrow().as_ref() {
            notice.set_alpha(alpha);
        }
    }

    fn hide_notice(&self, generation: u64) {
        if self.ivars().hud_gen.get() != generation {
            return;
        }
        if let Some(notice) = self.ivars().notice.borrow().as_ref() {
            notice.order_out();
            notice.set_alpha(1.0);
        }
    }

    /// Sample the triggering key — never a hard-coded Q — every `POLL_MS` until
    /// the guard says to stop. Common modes, so a tracked menu cannot stall it.
    fn start_polling(&self, key_code: u16) {
        self.stop_polling();
        let interval = quit_guard::POLL_MS as f64 / 1_000.0;
        let timer = unsafe {
            NSTimer::timerWithTimeInterval_target_selector_userInfo_repeats(
                interval,
                self,
                sel!(tarmacPoll:),
                None,
                true,
            )
        };
        unsafe { NSRunLoop::mainRunLoop().addTimer_forMode(&timer, NSRunLoopCommonModes) };
        *self.ivars().poll.borrow_mut() = Some((timer, key_code));
    }

    fn stop_polling(&self) {
        let running = self.ivars().poll.borrow_mut().take();
        if let Some((timer, _)) = running {
            timer.invalidate();
        }
    }
}

/// Run `f` against the live target on the main thread. `Err` means the event
/// loop has exited, which is the fade's signal to stop.
fn on_main(
    app: &AppHandle,
    f: impl FnOnce(&QuitTarget) + Send + 'static,
) -> Result<(), tauri::Error> {
    app.run_on_main_thread(move || {
        TARGET.with(|cell| {
            if let Some(target) = cell.borrow().as_ref() {
                f(target);
            }
        });
    })
}

/// The screen the notice belongs on. A hidden or minimized window reports no
/// screen worth using, so both fall back to the main one.
fn notice_screen(mtm: MainThreadMarker, app: &AppHandle) -> Option<Retained<NSScreen>> {
    let window = app.get_webview_window("main");
    let ns_window = window
        .as_ref()
        .and_then(|w| w.ns_window().ok())
        .map(|ptr| unsafe { &*(ptr as *const NSWindow) });
    let on_screen = window.as_ref().and_then(|w| w.is_visible().ok()).unwrap_or(false)
        && !ns_window.is_some_and(|w| w.isMiniaturized());
    crate::quit_notice::pick_screen(
        ns_window.and_then(|w| w.screen()),
        on_screen,
        NSScreen::mainScreen(mtm),
        NSScreen::screens(mtm).firstObject(),
    )
}

fn now_ms() -> u64 {
    // The same clock NSEvent.timestamp uses: seconds since boot, sleep
    // excluded. `Instant` cannot be compared with an event's timestamp.
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_UPTIME_RAW, &mut ts) };
    ts.tv_sec as u64 * 1_000 + ts.tv_nsec as u64 / 1_000_000
}

#[allow(unused_variables)]
fn log_quit_key(
    route: &Route,
    event_type: Option<usize>,
    is_repeat: bool,
    ev: &QuitEvent,
    press_ms: u64,
) {
    #[cfg(debug_assertions)]
    {
        // `-` for a field this event cannot carry: keyCode and isARepeat are
        // only valid on a key event, and there is no event at all behind a
        // VoiceOver press.
        let show = |v: Option<String>| v.unwrap_or_else(|| "-".to_string());
        eprintln!(
            "tarmac: quit-key route={} type={} repeat={} age_ms={} press_ms={}",
            match route {
                Route::Guard => "guard",
                Route::TerminateNow => "terminate",
            },
            show(event_type.map(|t| t.to_string())),
            show(ev.is_key_down.then(|| is_repeat.to_string())),
            show(event_type.map(|_| ev.age_ms.to_string())),
            show(event_type.map(|_| press_ms.to_string())),
        );
    }
}

// ------------------------------------------------------------------- app wiring

/// The app menu, with *Warn Before Quitting* inserted immediately above Quit.
/// `Menu::default` mints a fresh `terminate:` item, and `Builder::menu` installs
/// it before `.setup()` runs, so the retarget below sees the final menu.
pub fn app_menu(handle: &AppHandle, warn_before_quit: bool) -> tauri::Result<Menu<Wry>> {
    let menu = Menu::default(handle)?;
    let items = menu.items()?;
    let Some(app_submenu) = items.first().and_then(|item| item.as_submenu()) else {
        eprintln!("tarmac: no app submenu — Warn Before Quitting not installed");
        return Ok(menu);
    };
    let warn = CheckMenuItem::with_id(
        handle,
        WARN_BEFORE_QUIT_ID,
        WARN_BEFORE_QUIT_LABEL,
        true,
        warn_before_quit,
        None::<&str>,
    )?;
    // Quit is the last item; the check item goes just above it, as in Chromium.
    let position = app_submenu.items()?.len().saturating_sub(1);
    app_submenu.insert(&warn, position)?;
    Ok(menu)
}

/// muda has already flipped the item by the time this runs, so read it, never
/// toggle it.
pub fn on_menu_event(app: &AppHandle, event: &MenuEvent) {
    if event.id() != &MenuId::new(WARN_BEFORE_QUIT_ID) {
        return;
    }
    let Some(item) = warn_item(app) else { return };
    let Ok(checked) = item.is_checked() else { return };
    app.state::<QuitToggle>().set(checked);
    if let Err(e) = crate::app_prefs::save(&crate::bridge::app_prefs_path(), checked) {
        eprintln!("tarmac: could not save app prefs: {e}");
    }
}

fn warn_item(app: &AppHandle) -> Option<CheckMenuItem<Wry>> {
    let menu = app.menu()?;
    let items = menu.items().ok()?;
    let app_submenu = items.first().and_then(|item| item.as_submenu())?;
    let kind = app_submenu.get(WARN_BEFORE_QUIT_ID)?;
    kind.as_check_menuitem().cloned()
}

/// The red button hid the window; bring it back on the next activation or Dock
/// click. Both can fire for one click on an inactive app, so the restore is
/// handed out once (`window_lifecycle.rs`).
pub fn restore_window(app: &AppHandle) {
    if !app.state::<HiddenByClose>().take_restore() {
        return;
    }
    if let Some(window) = app.get_webview_window("main") {
        // show() first: set_focus() does nothing while a window is hidden.
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Retarget the Quit item and start listening for activation. Called from
/// `.setup()`, after the toggle state is managed.
pub fn install(app: AppHandle) {
    let mtm = MainThreadMarker::new().expect("tauri setup runs on the main thread");
    let target = QuitTarget::new(mtm, app);
    let retargeted = NSApplication::sharedApplication(mtm)
        .mainMenu()
        .map_or(0, |menu| retarget(&menu, &target));
    if retargeted == 0 {
        eprintln!("tarmac: quit guard disabled: no Quit menu item");
    }
    // tao's delegate implements no applicationDidBecomeActive:, so observe the
    // notification instead of touching its class. The centre does not retain an
    // observer, which the thread_local below is what keeps alive.
    unsafe {
        NSNotificationCenter::defaultCenter().addObserver_selector_name_object(
            &target,
            sel!(appDidBecomeActive:),
            Some(NSApplicationDidBecomeActiveNotification),
            None,
        );
    }
    TARGET.with(|cell| *cell.borrow_mut() = Some(target));
}

/// Every `terminate:` item in the menu tree, so the walk and `dev_quit_guard`'s
/// report agree on what "retargeted" means.
fn retarget(menu: &NSMenu, target: &QuitTarget) -> usize {
    let mut count = 0;
    for index in 0..menu.numberOfItems() {
        let Some(item) = menu.itemAtIndex(index) else { continue };
        if item.action() == Some(sel!(terminate:)) {
            unsafe {
                item.setTarget(Some(target));
                item.setAction(Some(sel!(tarmacQuit:)));
            }
            count += 1;
        } else if let Some(submenu) = item.submenu() {
            count += retarget(&submenu, target);
        }
    }
    count
}

/// Whether the guard still owns Quit. `make qa`'s D11 asserts this, because
/// anything that replaces the app menu silently drops the retarget. Only
/// `QuitTarget` defines `tarmacQuit:`, so the selector names our item — but the
/// target is held WEAKLY, so a dropped `TARGET` leaves the selector in place on
/// a nil target and AppKit quietly disables the item. Both have to hold.
#[cfg(debug_assertions)]
fn is_retargeted(mtm: MainThreadMarker) -> bool {
    fn walk(menu: &NSMenu) -> (usize, usize) {
        let (mut mine, mut native) = (0, 0);
        for index in 0..menu.numberOfItems() {
            let Some(item) = menu.itemAtIndex(index) else { continue };
            match item.action() {
                Some(action) if action == sel!(tarmacQuit:) => {
                    mine += usize::from(item.target().is_some());
                }
                Some(action) if action == sel!(terminate:) => native += 1,
                _ => {
                    if let Some(submenu) = item.submenu() {
                        let (m, n) = walk(&submenu);
                        mine += m;
                        native += n;
                    }
                }
            }
        }
        (mine, native)
    }
    let Some(menu) = NSApplication::sharedApplication(mtm).mainMenu() else { return false };
    let (mine, native) = walk(&menu);
    mine > 0 && native == 0
}

/// Dev-only: what the QA driver reports as `quit_guard`. Every fact is read in
/// one main-thread hop, so a snapshot that matches a press also shows the phase
/// and notice that press produced. Without a `QuitTarget` (2609.0016's S37
/// knockout) the guard has no phase or press to report; `retargeted: false` is
/// what carries the meaning.
#[cfg(debug_assertions)]
#[tauri::command]
pub fn dev_quit_guard(app: AppHandle) -> serde_json::Value {
    type Facts = (String, Option<(bool, f64)>, Option<(u64, Route, i64)>);
    let (tx, rx) = std::sync::mpsc::channel();
    let asked = app.run_on_main_thread(move || {
        let mtm = MainThreadMarker::new().expect("run_on_main_thread runs on the main thread");
        let facts: Option<Facts> = TARGET.with(|cell| {
            cell.borrow().as_ref().map(|target| {
                let ivars = target.ivars();
                (
                    quit_guard::phase_name(ivars.guard.borrow().phase()).to_string(),
                    ivars.notice.borrow().as_ref().map(|n| (n.is_visible(), n.alpha())),
                    ivars.last_press.get(),
                )
            })
        });
        let _ = tx.send((is_retargeted(mtm), facts));
    });
    let (retargeted, facts) = match asked {
        Ok(()) => rx.recv_timeout(Duration::from_millis(500)).unwrap_or((false, None)),
        Err(_) => (false, None),
    };
    let (phase, notice, last_press) = facts.unwrap_or_else(|| ("idle".to_string(), None, None));
    let (visible, alpha) = notice.unwrap_or((false, 0.0));
    serde_json::json!({
        "retargeted": retargeted,
        "enabled": app.state::<QuitToggle>().get(),
        "phase": phase,
        "notice": { "visible": visible, "alpha": alpha },
        "last_press": last_press.map(|(press_ms, route, age_ms)| serde_json::json!({
            "press_ms": press_ms,
            "route": quit_guard::route_name(&route),
            "age_ms": age_ms,
        })),
    })
}

// ------------------------------------------------------------- tarmac dev press
// Dev-only (spec 2609.0018, #183): a native ⌘ chord posted in-process. Every
// AppKit step is a `run_on_main_thread` hop and every wait an async sleep, so
// the command never blocks the main thread — which is what lets the page
// receive the key it posts.

/// A press that names no `--hold`. Long enough that a double tap quits on
/// release, as a real one does, not on the first poll.
#[cfg(debug_assertions)]
const TAP_HOLD_MS: u64 = 100;
/// How long activation may take to key the window. Spike 5 measured 7–31 ms;
/// this stays inside the backend's 2 s slack with room for the hops.
#[cfg(debug_assertions)]
const KEY_WAIT_MS: u64 = 1_000;

#[cfg(debug_assertions)]
#[tauri::command]
pub async fn dev_press(
    app: AppHandle,
    combo: String,
    hold_ms: Option<u32>,
    age_ms: Option<u32>,
    busy_ms: Option<u32>,
) -> Result<serde_json::Value, serde_json::Value> {
    use crate::dev_press::{parse_chord, ChordError};
    use tarmac_protocol::dev::{AGE_MS_MAX, BUSY_MS_MAX, HOLD_MS_MAX};

    let err = |code: &str, message: String| serde_json::json!({ "error": code, "message": message });
    let unresponsive = || err("app_unresponsive", "the event loop is exiting".into());

    // The wire accepts any u32; the CLI already refused these, so this is only
    // a guard against a hand-built frame.
    let in_range = hold_ms.is_none_or(|h| (1..=HOLD_MS_MAX).contains(&h))
        && age_ms.is_none_or(|a| a <= AGE_MS_MAX)
        && busy_ms.is_none_or(|b| (1..=BUSY_MS_MAX).contains(&b))
        && !(busy_ms.is_some() && age_ms.is_some());
    if !in_range {
        return Err(err("bad_request", "hold, age or busy out of range, or busy with age".into()));
    }
    let hold = hold_ms.map_or(TAP_HOLD_MS, u64::from);
    let age = age_ms.map_or(0, u64::from);

    let chord = match parse_chord(&combo) {
        Ok(chord) => chord,
        Err(ChordError::Unsupported(m)) => return Err(err("unsupported_combo", m)),
        Err(ChordError::Bad(m)) => return Err(err("bad_combo", m)),
    };

    let refused = on_main_async(&app, {
        let chord = chord.clone();
        move |mtm| quit_chord_refused(mtm, &chord)
    })
    .await
    .ok_or_else(unresponsive)?;
    if refused {
        return Err(err(
            "not_retargeted",
            format!("`{combo}` would reach a native terminate: item, or a Quit item with no guard behind it; not posted"),
        ));
    }

    let mut key = on_main_async(&app, window_is_key).await.ok_or_else(unresponsive)?;
    let activated = !key;
    if !key {
        on_main_async(&app, |mtm| {
            // Spike 5: the only call that takes focus from an unrelated app.
            #[allow(deprecated)]
            NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
        })
        .await
        .ok_or_else(unresponsive)?;
        let deadline = std::time::Instant::now() + Duration::from_millis(KEY_WAIT_MS);
        while !key {
            if std::time::Instant::now() >= deadline {
                return Err(err(
                    "not_key",
                    "activation was refused (a locked screen?); click the dev window and re-run".into(),
                ));
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
            key = on_main_async(&app, window_is_key).await.ok_or_else(unresponsive)?;
        }
    }

    if let Some(busy) = busy_ms {
        let window = app
            .get_webview_window("main")
            .ok_or_else(|| err("app_not_ready", "no main window".into()))?;
        // Braces: wry runs this as a global script, and a top-level `const`
        // would make the second `--busy` in one page load a SyntaxError.
        window
            .eval(format!("{{ const t = performance.now(); while (performance.now() - t < {busy}); }}"))
            .map_err(|e| err("app_unresponsive", e.to_string()))?;
        // Off the main thread, so the loop is running before the key arrives.
        tokio::time::sleep(Duration::from_millis(30)).await;
    }

    let (stamp_ms, until) = on_main_async(&app, {
        let chord = chord.clone();
        move |mtm| {
            let now = now_ms();
            let until = now + hold;
            TARGET.with(|cell| {
                if let Some(target) = cell.borrow().as_ref() {
                    target.ivars().held.set(Some((chord.key_code, until)));
                }
            });
            let stamp_ms = now.saturating_sub(age);
            post_key(mtm, &chord, NSEventType::KeyDown, stamp_ms).map(|()| (stamp_ms, until))
        }
    })
    .await
    .ok_or_else(unresponsive)?
    .ok_or_else(|| err("app_not_ready", "no main window to post into".into()))?;

    // The next press may re-arm `held`, so the release captures its own time.
    // By then the app may be exiting; a failed hop is nothing to report.
    let release = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(until.saturating_sub(now_ms()))).await;
        let _ = on_main_async(&release, move |mtm| post_key(mtm, &chord, NSEventType::KeyUp, now_ms())).await;
    });

    Ok(serde_json::json!({
        "combo": combo,
        "press_ms": stamp_ms,
        "hold_ms": hold,
        "activated": activated,
        "busy_ms": busy_ms,
    }))
}

/// One main-thread hop with a value back. `None` means the event loop is
/// exiting: the hop was refused, or its closure never ran.
#[cfg(debug_assertions)]
async fn on_main_async<T: Send + 'static>(
    app: &AppHandle,
    f: impl FnOnce(MainThreadMarker) -> T + Send + 'static,
) -> Option<T> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let asked = app.run_on_main_thread(move || {
        let mtm = MainThreadMarker::new().expect("run_on_main_thread runs on the main thread");
        let _ = tx.send(f(mtm));
    });
    match asked {
        Ok(()) => rx.await.ok(),
        Err(_) => None,
    }
}

/// Step 4.2: would this chord reach a native `terminate:` item, or a Quit item
/// whose guard is gone (its target dropped, so AppKit disabled it)? Walked the
/// way `is_retargeted` walks, so the two agree on what the menu holds.
#[cfg(debug_assertions)]
fn quit_chord_refused(mtm: MainThreadMarker, chord: &Chord) -> bool {
    fn walk(menu: &NSMenu, chord: &Chord) -> bool {
        for index in 0..menu.numberOfItems() {
            let Some(item) = menu.itemAtIndex(index) else { continue };
            let native = item.action() == Some(sel!(terminate:));
            let orphaned = item.action() == Some(sel!(tarmacQuit:)) && item.target().is_none();
            if native || orphaned {
                let key_equivalent = item.keyEquivalent().to_string();
                let mask = item.keyEquivalentModifierMask().0 as u64;
                if matches_item(chord, &key_equivalent, mask) {
                    return true;
                }
            } else if let Some(submenu) = item.submenu() {
                if walk(&submenu, chord) {
                    return true;
                }
            }
        }
        false
    }
    NSApplication::sharedApplication(mtm).mainMenu().is_some_and(|menu| walk(&menu, chord))
}

/// Step 4.3's one-line test: only a key window on an active app takes the
/// page's path (spike 2).
#[cfg(debug_assertions)]
fn window_is_key(mtm: MainThreadMarker) -> bool {
    let ns_app = NSApplication::sharedApplication(mtm);
    ns_app.isActive() && ns_app.mainWindow().is_some_and(|w| w.isKeyWindow())
}

/// Post one key event for `chord` to the main window. `None` when there is no
/// main window to address.
#[cfg(debug_assertions)]
fn post_key(
    mtm: MainThreadMarker,
    chord: &Chord,
    kind: NSEventType,
    stamp_ms: u64,
) -> Option<()> {
    use objc2_app_kit::{NSEvent, NSEventModifierFlags};
    use objc2_foundation::{NSPoint, NSString};

    let ns_app = NSApplication::sharedApplication(mtm);
    let window_number = ns_app.mainWindow()?.windowNumber();
    let chars = NSString::from_str(&chord.chars);
    let event = NSEvent::keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode(
        kind,
        NSPoint::new(0.0, 0.0),
        NSEventModifierFlags(chord.flags as usize),
        stamp_ms as f64 / 1000.0,
        window_number,
        None,
        &chars,
        &chars,
        false,
        chord.key_code,
    )?;
    ns_app.postEvent_atStart(&event, false);
    Some(())
}
