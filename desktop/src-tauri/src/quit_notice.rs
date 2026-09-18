//! Where the "Hold ⌘Q to Quit" notice goes (spec 2609.0016, issue #171).
//!
//! The panel itself is AppKit and lives in the wiring below; the two decisions
//! it needs — which screen, and where on it — are here, taken as plain values
//! so they can be tested. A hidden or minimized window reports no useful screen
//! (`NSWindow.screen` is documented to return nil for an off-screen window and
//! says nothing about a miniaturized one), so both fall back to the main one.

/// Chromium's panel size (`confirm_quit_panel_controller.mm`).
const NOTICE_W: f64 = 350.0;
const NOTICE_H: f64 = 70.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NoticeRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

pub fn notice_frame(visible_frame: NoticeRect) -> NoticeRect {
    NoticeRect {
        x: visible_frame.x + (visible_frame.w - NOTICE_W) / 2.0,
        y: visible_frame.y + (visible_frame.h - NOTICE_H) / 2.0,
        w: NOTICE_W,
        h: NOTICE_H,
    }
}

/// Where the text sits inside the slab. An `NSTextField` draws its single line
/// at the TOP of its frame, so the label is sized to its glyphs and that tight
/// box is centred — giving it the slab's full height would ride the text high
/// (found in QA, Q1).
pub fn label_y(notice_h: f64, text_h: f64) -> f64 {
    ((notice_h - text_h) / 2.0).max(0.0)
}

/// `window_on_screen` is "visible and not minimized".
pub fn pick_screen<T>(
    window_screen: Option<T>,
    window_on_screen: bool,
    main_screen: Option<T>,
    first_screen: Option<T>,
) -> Option<T> {
    window_screen
        .filter(|_| window_on_screen)
        .or(main_screen)
        .or(first_screen)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// S28 — centred on the screen's usable area.
    #[test]
    fn the_notice_is_centred_in_the_visible_frame() {
        assert_eq!(
            notice_frame(NoticeRect { x: 100.0, y: 50.0, w: 1000.0, h: 800.0 }),
            NoticeRect { x: 425.0, y: 415.0, w: NOTICE_W, h: NOTICE_H }
        );
    }

    /// S39 — the text is centred on the slab's own centre line, not hung from
    /// its top edge.
    #[test]
    fn the_label_is_centred_in_the_slab() {
        assert_eq!(label_y(NOTICE_H, 29.0), 20.5);
        assert_eq!(label_y(NOTICE_H, NOTICE_H), 0.0);
        // Text taller than the slab starts at the top edge rather than above it.
        assert_eq!(label_y(NOTICE_H, 80.0), 0.0);
    }

    /// S29 — the window's own screen while it is on one; the main screen while
    /// it is hidden or minimized, which is where the user is looking.
    #[test]
    fn the_notice_follows_the_window_until_it_leaves_the_screen() {
        assert_eq!(pick_screen(Some("win"), true, Some("main"), Some("first")), Some("win"));
        assert_eq!(pick_screen(Some("win"), false, Some("main"), Some("first")), Some("main"));
        assert_eq!(pick_screen(None, true, Some("main"), Some("first")), Some("main"));
        assert_eq!(pick_screen(None, false, None, Some("first")), Some("first"));
        assert_eq!(pick_screen::<&str>(None, false, None, None), None);
    }
}

// --------------------------------------------------------------------- the panel
// AppKit from here down, main-thread-only, and untestable shell: the decisions
// it needs are the two functions above. Covered by `desktop/qa/hold-to-quit-qa.md`.

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{msg_send, ClassType, MainThreadMarker};
use objc2_app_kit::{
    NSAccessibilityAnnouncementKey, NSAccessibilityAnnouncementRequestedNotification,
    NSAccessibilityPostNotificationWithUserInfo, NSAccessibilityPriorityKey,
    NSAccessibilityPriorityLevel, NSApplication, NSBackingStoreType, NSBox, NSBoxType, NSColor,
    NSFont, NSPanel, NSScreen, NSTextAlignment, NSTextField, NSTitlePosition,
    NSWindowCollectionBehavior, NSWindowStyleMask,
};
use objc2_foundation::{NSDictionary, NSNumber, NSPoint, NSRect, NSSize, NSString};

/// Chromium's look (`confirm_quit_panel_controller.mm:210-221`): a 350×70 slab
/// at white 0.2 / alpha 0.75, with bold 24 pt white text.
const FILL_WHITE: f64 = 0.2;
const FILL_ALPHA: f64 = 0.75;
const CORNER_RADIUS: f64 = 20.0;
const FONT_SIZE: f64 = 24.0;
/// Above the cockpit window, so clicking the board cannot bury the notice.
const NOTICE_LEVEL: isize = 3; // NSFloatingWindowLevel

pub struct Notice {
    panel: Retained<NSPanel>,
    label: Retained<NSTextField>,
}

impl Notice {
    /// A borderless, non-activating panel: it must never take key focus from
    /// the terminal, and it has to survive the app being deactivated mid-hold
    /// (⌘Tab), which NSPanel otherwise undoes for us.
    pub fn new(mtm: MainThreadMarker) -> Self {
        let frame = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(NOTICE_W, NOTICE_H));
        let panel = NSPanel::initWithContentRect_styleMask_backing_defer(
            mtm.alloc(),
            frame,
            NSWindowStyleMask::NonactivatingPanel,
            NSBackingStoreType::Buffered,
            false,
        );
        panel.setOpaque(false);
        panel.setBackgroundColor(Some(&NSColor::clearColor()));
        panel.setHasShadow(false);
        panel.setIgnoresMouseEvents(true);
        panel.setHidesOnDeactivate(false);
        panel.setLevel(NOTICE_LEVEL);
        panel.setCollectionBehavior(
            NSWindowCollectionBehavior::CanJoinAllSpaces
                | NSWindowCollectionBehavior::FullScreenAuxiliary,
        );

        let slab: Retained<NSBox> = unsafe { msg_send![mtm.alloc::<NSBox>(), initWithFrame: frame] };
        slab.setBoxType(NSBoxType::Custom);
        slab.setTitlePosition(NSTitlePosition::NoTitle);
        slab.setBorderWidth(0.0);
        slab.setCornerRadius(CORNER_RADIUS);
        // An NSBox insets its content view by 5 pt plus the border, and
        // `addSubview` goes to that content view — so a label centred on the
        // slab's own height would sit 6 pt high and 6 pt right (measured in QA,
        // Q1). Zeroing the margins makes the content view the slab.
        slab.setContentViewMargins(NSSize::new(0.0, 0.0));
        slab.setFillColor(&NSColor::colorWithWhite_alpha(FILL_WHITE, FILL_ALPHA));

        let label = NSTextField::labelWithString(&NSString::from_str(""), mtm);
        label.setAlignment(NSTextAlignment::Center);
        label.setFont(Some(&NSFont::boldSystemFontOfSize(FONT_SIZE)));
        label.setTextColor(Some(&NSColor::whiteColor()));
        slab.addSubview(&label);
        panel.setContentView(Some(slab.as_super()));

        Self { panel, label }
    }

    /// Put the notice up at full opacity on `screen`, and announce it: a
    /// borderless window is not announced by itself, and the announcement goes
    /// to the application element because `mainWindow` is nil while the window
    /// is hidden (`NSAccessibilityConstants.h:492-493`).
    pub fn show(&self, mtm: MainThreadMarker, text: &str, screen: Option<Retained<NSScreen>>) {
        self.label.setStringValue(&NSString::from_str(text));
        // Re-laid out per text: a remapped shortcut ("Hold ⌥⌘Q to Quit") is a
        // different string, and only the fitted height can be centred.
        self.label.sizeToFit();
        let text_height = self.label.frame().size.height;
        self.label.setFrame(NSRect::new(
            NSPoint::new(0.0, label_y(NOTICE_H, text_height)),
            NSSize::new(NOTICE_W, text_height),
        ));
        if let Some(screen) = screen {
            let visible = screen.visibleFrame();
            let frame = notice_frame(NoticeRect {
                x: visible.origin.x,
                y: visible.origin.y,
                w: visible.size.width,
                h: visible.size.height,
            });
            self.panel.setFrame_display(
                NSRect::new(
                    NSPoint::new(frame.x, frame.y),
                    NSSize::new(frame.w, frame.h),
                ),
                false,
            );
        }
        self.set_alpha(1.0);
        self.panel.orderFrontRegardless();
        announce(mtm, text);
    }

    pub fn set_alpha(&self, alpha: f64) {
        self.panel.setAlphaValue(alpha);
    }

    pub fn order_out(&self) {
        self.panel.orderOut(None);
    }
}

fn announce(mtm: MainThreadMarker, text: &str) {
    let app = NSApplication::sharedApplication(mtm);
    let priority = NSNumber::new_isize(NSAccessibilityPriorityLevel::High.0);
    let info: Retained<NSDictionary<NSString, AnyObject>> = NSDictionary::from_retained_objects(
        &[
            unsafe { NSAccessibilityAnnouncementKey },
            unsafe { NSAccessibilityPriorityKey },
        ],
        &[
            Retained::into_super(NSString::from_str(text)).into(),
            Retained::into_super(Retained::into_super(priority)).into(),
        ],
    );
    unsafe {
        NSAccessibilityPostNotificationWithUserInfo(
            &app,
            NSAccessibilityAnnouncementRequestedNotification,
            Some(&info),
        )
    };
}
