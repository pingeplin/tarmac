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
//!     is polled off the main thread and hops back with `run_on_main_thread`.

use std::cell::{Cell, RefCell};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject, NSObjectProtocol};
use objc2::{define_class, msg_send, sel, DefinedClass, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSApplication, NSApplicationDidBecomeActiveNotification, NSEventType, NSMenu, NSMenuItem,
    NSScreen, NSWindow,
};
use objc2_core_graphics::{CGEventSource, CGEventSourceStateID};
use objc2_foundation::NSNotificationCenter;
use tauri::menu::{CheckMenuItem, Menu, MenuEvent, MenuId};
use tauri::{AppHandle, Manager, Wry};

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
// It is also where the guard, the notice and the two generation counters live:
// all of it is main-thread-only, and none of it can ride a `run_on_main_thread`
// closure (AppKit objects are not `Send`).
thread_local! {
    static TARGET: RefCell<Option<Retained<QuitTarget>>> = const { RefCell::new(None) };
}

struct QuitIvars {
    app: AppHandle,
    guard: RefCell<QuitGuard>,
    notice: RefCell<Option<Notice>>,
    /// Bumped by `StartPolling`/`StopPolling`; a sampler whose generation is
    /// stale stops, and its queued hop does nothing.
    poll_gen: Arc<AtomicU64>,
    /// Bumped by `ShowHud`, so a linger or fade left over from an earlier tap
    /// cannot take the new notice away.
    hud_gen: Cell<u64>,
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
            poll_gen: Arc::new(AtomicU64::new(0)),
            hud_gen: Cell::new(0),
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
            item_key_equivalent: key_equivalent.clone(),
            age_ms: quit_guard::age_ms(now_ms(), press_ms),
        };
        let enabled = self.ivars().app.state::<QuitToggle>().get();
        let route = self.ivars().guard.borrow().route(&ev, enabled);
        log_quit_key(&route, event.as_ref().map(|e| e.r#type().0), is_key_down, is_repeat, &ev, press_ms);

        match route {
            Route::TerminateNow => ns_app.terminate(None),
            Route::Guard => {
                let effects = self.ivars().guard.borrow_mut().on_quit_key(press_ms, key_code, is_repeat);
                self.apply(mtm, effects, Some((&key_equivalent, item_mask)));
            }
        }
    }

    fn on_poll(&self, sampled_ms: u64, key_down: bool) {
        let effects = self.ivars().guard.borrow_mut().on_poll(sampled_ms, key_down);
        if !effects.is_empty() {
            // No shortcut to name: only a chord can raise `ShowHud`.
            self.apply(MainThreadMarker::from(self), effects, None);
        }
    }

    fn apply(&self, mtm: MainThreadMarker, effects: Vec<Effect>, shortcut: Option<(&str, u64)>) {
        for effect in effects {
            match effect {
                Effect::ShowHud => {
                    if let Some((key_equivalent, mask)) = shortcut {
                        self.show_notice(mtm, key_equivalent, mask);
                    }
                }
                Effect::LingerThenFadeHud => self.linger_then_fade(),
                Effect::HideWindows => {
                    // Also cancels a pending linger or fade: past the threshold
                    // the notice stays up over the hidden window until the app
                    // exits, and a second tap inherits the first tap's notice.
                    self.ivars().hud_gen.set(self.ivars().hud_gen.get() + 1);
                    if let Some(window) = self.ivars().app.get_webview_window("main") {
                        let _ = window.hide();
                    }
                }
                Effect::StartPolling(key_code) => self.start_polling(key_code),
                Effect::StopPolling => {
                    self.ivars().poll_gen.fetch_add(1, Ordering::SeqCst);
                }
                Effect::Exit => self.ivars().app.exit(0),
            }
        }
    }

    fn show_notice(&self, mtm: MainThreadMarker, key_equivalent: &str, mask: u64) {
        self.ivars().hud_gen.set(self.ivars().hud_gen.get() + 1);
        let mut slot = self.ivars().notice.borrow_mut();
        let notice = slot.get_or_insert_with(|| Notice::new(mtm));
        notice.show(
            mtm,
            &quit_guard::notice_text(key_equivalent, mask),
            notice_screen(mtm, &self.ivars().app),
        );
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

    /// Sample the triggering key — never a hard-coded Q — until the guard says
    /// to stop or the event loop is gone.
    fn start_polling(&self, key_code: u16) {
        let generation = self.ivars().poll_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let poll_gen = self.ivars().poll_gen.clone();
        let app = self.ivars().app.clone();
        std::thread::spawn(move || loop {
            let held =
                CGEventSource::key_state(CGEventSourceStateID::CombinedSessionState, key_code);
            let sampled_ms = now_ms();
            if poll_gen.load(Ordering::SeqCst) != generation {
                return;
            }
            let still_ours = poll_gen.clone();
            let hopped = on_main(&app, move |target| {
                if still_ours.load(Ordering::SeqCst) == generation {
                    target.on_poll(sampled_ms, held);
                }
            });
            if hopped.is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(quit_guard::POLL_MS));
        });
    }
}

/// Run `f` against the live target on the main thread. `Err` means the event
/// loop has exited, which is every poller's signal to stop.
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
    is_key_down: bool,
    is_repeat: bool,
    ev: &QuitEvent,
    press_ms: u64,
) {
    #[cfg(debug_assertions)]
    {
        let show = |v: String, present: bool| if present { v } else { "-".to_string() };
        eprintln!(
            "tarmac: quit-key route={} type={} repeat={} age_ms={} press_ms={}",
            match route {
                Route::Guard => "guard",
                Route::TerminateNow => "terminate",
            },
            show(event_type.unwrap_or_default().to_string(), event_type.is_some()),
            show(is_repeat.to_string(), is_key_down),
            show(ev.age_ms.to_string(), event_type.is_some()),
            show(press_ms.to_string(), event_type.is_some()),
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
    let restore = app
        .state::<Mutex<HiddenByClose>>()
        .lock()
        .expect("hidden_by_close lock")
        .take_restore();
    if !restore {
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
/// anything that replaces the app menu silently drops the retarget.
#[cfg(debug_assertions)]
fn is_retargeted(mtm: MainThreadMarker) -> bool {
    fn walk(menu: &NSMenu, ours: Option<&AnyObject>) -> (usize, usize) {
        let (mut mine, mut native) = (0, 0);
        for index in 0..menu.numberOfItems() {
            let Some(item) = menu.itemAtIndex(index) else { continue };
            match item.action() {
                Some(action) if action == sel!(tarmacQuit:) => {
                    let same = match (item.target(), ours) {
                        (Some(target), Some(ours)) => std::ptr::eq(&*target as *const _, ours as *const _),
                        _ => false,
                    };
                    mine += usize::from(same);
                }
                Some(action) if action == sel!(terminate:) => native += 1,
                _ => {
                    if let Some(submenu) = item.submenu() {
                        let (m, n) = walk(&submenu, ours);
                        mine += m;
                        native += n;
                    }
                }
            }
        }
        (mine, native)
    }
    let ours = TARGET.with(|cell| {
        cell.borrow().as_ref().map(|t| Retained::as_ptr(t) as *const AnyObject)
    });
    let Some(ours) = ours else { return false };
    let Some(menu) = NSApplication::sharedApplication(mtm).mainMenu() else { return false };
    let (mine, native) = walk(&menu, Some(unsafe { &*ours }));
    mine > 0 && native == 0
}

/// Dev-only: what the QA driver reports as `quit_guard`.
#[cfg(debug_assertions)]
#[tauri::command]
pub fn dev_quit_guard(app: AppHandle) -> serde_json::Value {
    let (tx, rx) = std::sync::mpsc::channel();
    let asked = app.run_on_main_thread(move || {
        let mtm = MainThreadMarker::new().expect("run_on_main_thread runs on the main thread");
        let _ = tx.send(is_retargeted(mtm));
    });
    let retargeted = match asked {
        Ok(()) => rx.recv_timeout(Duration::from_millis(500)).unwrap_or(false),
        Err(_) => false,
    };
    serde_json::json!({
        "retargeted": retargeted,
        "enabled": app.state::<QuitToggle>().get(),
    })
}
