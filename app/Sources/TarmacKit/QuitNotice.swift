/// Where the "Hold ⌘Q to Quit" notice goes (spec 2609.0016), and whether the
/// guard behind it still owns Quit. The panel itself is AppKit; the decisions it
/// needs are here as plain values. Ports `desktop/src-tauri/src/quit_notice.rs`.
public enum QuitNotice {
    /// Chromium's panel size (`confirm_quit_panel_controller.mm`).
    public static let width = 350.0
    public static let height = 70.0

    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }
    }

    public static func frame(visibleFrame: Rect) -> Rect {
        Rect(
            x: visibleFrame.x + (visibleFrame.w - width) / 2,
            y: visibleFrame.y + (visibleFrame.h - height) / 2,
            w: width,
            h: height
        )
    }

    /// Where the text sits inside the slab. An `NSTextField` draws its single
    /// line at the TOP of its frame, so the label is sized to its glyphs and that
    /// tight box is centred — giving it the slab's full height would ride the
    /// text high.
    public static func labelY(noticeHeight: Double, textHeight: Double) -> Double {
        max((noticeHeight - textHeight) / 2, 0)
    }

    /// `windowOnScreen` is "visible and not minimized". A hidden or minimized
    /// window reports no useful screen (`NSWindow.screen` is documented to return
    /// nil for an off-screen window and says nothing about a miniaturized one),
    /// so both fall back to the main one.
    public static func pickScreen<Screen>(
        windowScreen: Screen?, windowOnScreen: Bool, mainScreen: Screen?, firstScreen: Screen?
    ) -> Screen? {
        (windowOnScreen ? windowScreen : nil) ?? mainScreen ?? firstScreen
    }

    /// One step of the notice's ending: `afterMs` from the early release, the
    /// panel takes `alpha`.
    public struct FadeStep: Equatable, Sendable {
        public var afterMs: UInt64
        public var alpha: Double
    }

    /// Chromium's ending for a tap: the notice sits for `QuitGuard.lingerMs`,
    /// then fades over `QuitGuard.fadeMs`.
    public static var fadeSteps: [FadeStep] {
        (1...QuitGuard.fadeSteps).map { step in
            FadeStep(
                afterMs: QuitGuard.lingerMs + UInt64(step - 1) * QuitGuard.fadeStepMs,
                alpha: QuitGuard.fadeAlpha(step: step)
            )
        }
    }

    /// When the faded notice is taken off screen.
    public static var dismissAfterMs: UInt64 {
        QuitGuard.lingerMs + QuitGuard.fadeMs
    }

    /// The QA driver's `retargeted` (spec 2609.0018): at least one Quit item
    /// reaches the guard, and none is left on the native `terminate:` that would
    /// quit past it.
    public static func guardOwnsQuit(guardedItems: Int, nativeItems: Int) -> Bool {
        guardedItems > 0 && nativeItems == 0
    }
}
