import AppKit
import QuartzCore

/// Cockpit dock pane (crib §4 / migration-plan Phase 5 `.tm-dockpane`): the
/// focused terminal docks into a viewport-fixed bottom pane while the board pans
/// freely behind it. Fixed to the bottom of the board area (left 0, right 0,
/// bottom 0, above the status bar); height = 40% of the board height. bg
/// `term-bg #31363b`, 1px top border `#5a626a` (= liftBorder), upward shadow
/// `0 -24px 60px rgba(0,0,0,0.6)`.
///
/// A 34px `.dhd` header (bg2, 1px line-soft bottom border, 11px mono text) shows
/// the term kind glyph `›_` + the term label, with a right-aligned faint
/// `esc ↩` hint. The SwiftTerm view REPARENTS from its board card body into
/// `body` on dock, and back on undock (AppController owns the reparent so the
/// delegate + first responder stay intact).
@MainActor
final class DockPaneView: NSView {
    static let headerHeight: CGFloat = 34
    /// Pane height = this fraction of the board height (crib §4: 40%).
    static let heightFraction: CGFloat = 0.4
    /// Card body padding (crib §4 dock body `padding 12px 16px`; the F3 mock
    /// uses 12/16 — distinct from the on-board term card's 10/14).
    private static let bodyPadX: CGFloat = 16
    private static let bodyPadY: CGFloat = 12

    /// The reparented terminal body container; AppController adds the SwiftTerm
    /// view here on dock and removes it on undock.
    let body = FlippedColumnView()
    private let header = FlippedColumnView()
    private let topBorder = NSView()
    private let bottomBorder = NSView()
    private let kindGlyph = NSTextField(labelWithString: "›_")
    private let labelField = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "esc ↩")

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.termBg.cgColor

        // Upward shadow `0 -24px 60px rgba(0,0,0,0.6)` (positive y in a flipped
        // view points downward; the dock lifts toward the board above it).
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = NSSize(width: 0, height: 24)
        shadow.shadowBlurRadius = 60
        self.shadow = shadow

        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = Theme.liftBorder.cgColor
        addSubview(topBorder)

        // .dhd — bg2, line-soft bottom border, 11px mono text.
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bg2.cgColor
        addSubview(header)

        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = Theme.lineSoft.cgColor
        header.addSubview(bottomBorder)

        kindGlyph.font = Theme.mono(11)
        kindGlyph.textColor = Theme.faint // .dhd .kind faint
        header.addSubview(kindGlyph)

        labelField.font = Theme.mono(11)
        labelField.textColor = Theme.text
        labelField.lineBreakMode = .byTruncatingTail
        header.addSubview(labelField)

        // Right-aligned faint hint `esc ↩` (.dhd .mr; 10px in the mock, faint).
        hint.font = Theme.mono(10)
        hint.textColor = Theme.faint
        hint.alignment = .right
        header.addSubview(hint)

        addSubview(body)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The term card's current header label (process name / shell basename).
    func setTermLabel(_ text: String) {
        labelField.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        topBorder.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        header.frame = NSRect(x: 0, y: 1, width: bounds.width, height: Self.headerHeight)
        bottomBorder.frame = NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1)

        let hh = Self.headerHeight
        var x: CGFloat = 14 // .dhd padding 0 14
        let glyphSize = kindGlyph.fittedSize
        kindGlyph.frame = NSRect(
            x: x,
            y: ((hh - glyphSize.height) / 2).rounded(),
            width: glyphSize.width,
            height: glyphSize.height
        )
        x = kindGlyph.frame.maxX + 8 // .dhd gap 8

        let hintSize = hint.fittedSize
        let hintX = bounds.width - 14 - hintSize.width
        hint.frame = NSRect(
            x: hintX,
            y: ((hh - hintSize.height) / 2).rounded(),
            width: hintSize.width,
            height: hintSize.height
        )

        let labelH = labelField.fittedSize.height
        labelField.frame = NSRect(
            x: x,
            y: ((hh - labelH) / 2).rounded(),
            width: max(0, hintX - 8 - x),
            height: labelH
        )

        // Body fills below the header; the reparented terminal is inset by the
        // dock body padding (crib §4 dock body 12/16).
        let bodyTop = 1 + Self.headerHeight
        body.frame = NSRect(x: 0, y: bodyTop, width: bounds.width, height: max(0, bounds.height - bodyTop))
        if let terminal = body.subviews.first {
            terminal.frame = NSRect(
                x: Self.bodyPadX,
                y: Self.bodyPadY,
                width: max(0, body.bounds.width - Self.bodyPadX * 2),
                height: max(0, body.bounds.height - Self.bodyPadY * 2)
            )
        }
    }
}

/// Dashed slot ghost (crib §4 `.tm-slotghost`): while a terminal is docked, a
/// dashed outline sits at the term card's board position with a faint centered
/// `esc to return` label. 1.5px dashed line `#474e55` (= line), radius 10. Lives
/// in the board's card layer at the term card's world frame so it pans/zooms
/// with the board.
@MainActor
final class SlotGhostView: NSView {
    private let label = NSTextField(labelWithString: "esc to return")
    private let dashLayer = CAShapeLayer()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    // Click-through: the ghost never intercepts board panning.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // 1.5px dashed border, radius 10 (crib §4). A CAShapeLayer draws the
        // dash; a plain layer border can't be dashed.
        dashLayer.fillColor = NSColor.clear.cgColor
        dashLayer.strokeColor = Theme.line.cgColor
        dashLayer.lineWidth = 1.5
        dashLayer.lineDashPattern = [4, 4]
        layer?.addSublayer(dashLayer)

        label.font = Theme.mono(10)
        label.textColor = Theme.faint
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let inset = dashLayer.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        dashLayer.frame = bounds
        dashLayer.path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let size = label.fittedSize
        label.frame = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }
}
