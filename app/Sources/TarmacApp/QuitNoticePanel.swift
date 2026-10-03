import AppKit
import TarmacKit

/// The "Hold ⌘Q to Quit" notice: Chromium's confirm-quit slab, ported from
/// `desktop/src-tauri/src/quit_notice.rs`. Where it goes is `QuitNotice`'s
/// decision; this is only the panel.
@MainActor
final class QuitNoticePanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        let frame = NSRect(x: 0, y: 0, width: QuitNotice.width, height: QuitNotice.height)
        // Non-activating and click-through: the notice must never take key
        // focus from the terminal. `hidesOnDeactivate` off, because a panel
        // otherwise vanishes when the app is deactivated mid-hold (⌘Tab).
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Above the cockpit window, so clicking the board cannot bury it.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let slab = NSBox(frame: frame)
        slab.boxType = .custom
        slab.titlePosition = .noTitle
        slab.borderWidth = 0
        slab.cornerRadius = 20
        // An NSBox insets its content view by 5 pt plus the border, which would
        // put a label centred on the slab's own height 6 pt high and right.
        slab.contentViewMargins = .zero
        slab.fillColor = NSColor(white: 0.2, alpha: 0.75)

        label.alignment = .center
        label.font = .boldSystemFont(ofSize: 24)
        label.textColor = .white
        slab.addSubview(label)
        panel.contentView = slab
    }

    var isVisible: Bool { panel.isVisible }

    var alpha: Double {
        get { panel.alphaValue }
        set { panel.alphaValue = newValue }
    }

    /// Puts the notice up at full opacity on `screen` and announces it: a
    /// borderless window is not announced by itself, and the announcement goes
    /// to the application because there is no main window while it is hidden.
    func show(_ text: String, on screen: NSScreen?) {
        label.stringValue = text
        // Re-laid out per text: a remapped shortcut is a different string, and
        // only the fitted height can be centred.
        label.sizeToFit()
        let textHeight = label.frame.height
        label.frame = NSRect(
            x: 0,
            y: QuitNotice.labelY(noticeHeight: QuitNotice.height, textHeight: textHeight),
            width: QuitNotice.width,
            height: textHeight
        )
        if let visible = screen?.visibleFrame {
            let frame = QuitNotice.frame(visibleFrame: QuitNotice.Rect(
                x: visible.minX, y: visible.minY, w: visible.width, h: visible.height
            ))
            panel.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h), display: false)
        }
        alpha = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// Takes the notice down, ready to be shown again at full opacity.
    func dismiss() {
        panel.orderOut(nil)
        alpha = 1
    }
}
