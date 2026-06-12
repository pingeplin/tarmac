import AppKit
import QuartzCore
import TarmacKit

/// NSTextField's intrinsicContentSize under-reports its drawn width (cell
/// insets), which triggers spurious truncation at exact-fit frames; measure
/// via sizeToFit instead.
@MainActor
extension NSTextField {
    var fittedSize: NSSize {
        let saved = frame
        sizeToFit()
        let size = frame.size
        frame = saved
        return size
    }
}

/// `writing-mode: vertical-rl` (glyphs 90° clockwise, reading top→bottom):
/// frameCenterRotation clips layer-backed labels, so draw the string rotated.
@MainActor
final class VerticalHintView: NSView {
    var onClick: (() -> Void)?
    private let text: NSAttributedString

    init(text: NSAttributedString) {
        self.text = text
        let size = text.size()
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(size.height), height: ceil(size.width) + 2))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: bounds.width, y: 0)
        ctx.rotate(by: .pi / 2)
        text.draw(at: .zero)
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Non-focusable click target (focus rule: dock/index clicks never move
/// keyboard focus off the terminal).
@MainActor
final class ClickTargetView: NSView {
    var onClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    // Labels swallow mouseDown; capture clicks on children too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// One 30×30 dock icon per docs/m1/crib-dock-index.md §1.4–1.6.
@MainActor
final class DockIconView: NSView {
    let path: String
    var onClick: (() -> Void)?

    private let glyph = NSTextField(labelWithString: "¶")
    private let repoDot = NSView()
    private let unreadDot = NSView()
    private let halo = CALayer()
    private var hovered = false
    private var active = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    init(path: String) {
        self.path = path
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1

        halo.frame = bounds
        halo.cornerRadius = 7
        layer?.insertSublayer(halo, at: 0)

        glyph.font = Theme.mono(12)
        glyph.textColor = Theme.muted
        let glyphSize = glyph.intrinsicContentSize
        glyph.frame = NSRect(
            x: ((30 - glyphSize.width) / 2).rounded(),
            y: ((30 - glyphSize.height) / 2).rounded(),
            width: glyphSize.width,
            height: glyphSize.height
        )
        addSubview(glyph)

        repoDot.wantsLayer = true
        repoDot.layer?.cornerRadius = 3.5
        repoDot.frame = NSRect(x: 4, y: 4, width: 7, height: 7)
        addSubview(repoDot)

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 2.5
        unreadDot.layer?.backgroundColor = Theme.agent.cgColor
        unreadDot.frame = NSRect(x: 30 - 4 - 5, y: 4, width: 5, height: 5)
        addSubview(unreadDot)

        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(doc: RestoreDoc, active: Bool) {
        toolTip = doc.displayPath
        repoDot.layer?.backgroundColor =
            Theme.repoColor(index: doc.repoColor, fallbackName: doc.displayRepoName).cgColor
        unreadDot.isHidden = doc.read
        if self.active != active {
            self.active = active
            applyStyle()
        }
    }

    /// dockPulse ×3 per crib §1.6; every new file event restarts it. The ring's
    /// inner edge tracks the icon edge (bounds/borderWidth grow in lockstep),
    /// matching the CSS spread-only box-shadow.
    func restartPulse() {
        halo.removeAnimation(forKey: "dockPulse")
        guard !Theme.reduceMotion else { return }

        let keyTimes: [NSNumber] = [0, 0.6, 1]
        let timing = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let anim = CAKeyframeAnimation(keyPath: keyPath)
            anim.values = values
            anim.keyTimes = keyTimes
            anim.timingFunctions = timing
            anim.duration = 2.4
            return anim
        }
        let rest = NSRect(x: 0, y: 0, width: 30, height: 30)
        let spread = rest.insetBy(dx: -6, dy: -6)
        let group = CAAnimationGroup()
        group.animations = [
            keyframes("bounds", [NSValue(rect: rest), NSValue(rect: spread), NSValue(rect: spread)]),
            keyframes("cornerRadius", [7, 13, 13]),
            keyframes("borderWidth", [0, 6, 6]),
            keyframes("borderColor", [Theme.agentDim.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]),
        ]
        group.duration = 2.4
        group.repeatCount = 3
        halo.add(group, forKey: "dockPulse")
    }

    // Labels swallow mouseDown; capture clicks on children too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func applyStyle() {
        if active {
            layer?.backgroundColor = Theme.bg2.cgColor
            layer?.borderColor = Theme.line.cgColor
            glyph.textColor = Theme.text
        } else if hovered {
            layer?.backgroundColor = Theme.bg3.cgColor
            layer?.borderColor = Theme.line.cgColor
            glyph.textColor = Theme.muted
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            glyph.textColor = Theme.muted
        }
    }
}

/// The 46px dock strip (crib §1.3): icons → sep → vertical ⌘E hint, footer
/// glyph pinned to the bottom. Icons scroll (no visible scrollbar) on overflow.
@MainActor
final class DockView: NSView {
    var onPeek: ((String) -> Void)?
    var onToggleIndex: (() -> Void)?

    private let scroll = NSScrollView()
    private let iconsColumn = FlippedColumnView()
    private let rightHairline = NSView()
    private let sep = NSView()
    private let hint = VerticalHintView(text: NSAttributedString(
        string: "⌘E index",
        attributes: [
            .font: Theme.mono(9),
            .foregroundColor: Theme.faint,
            .kern: 9 * 0.1,
        ]
    ))
    private let footGlyph = NSTextField(labelWithString: "▞")

    private var icons: [String: DockIconView] = [:]
    private var orderedPaths: [String] = []

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor

        rightHairline.wantsLayer = true
        rightHairline.layer?.backgroundColor = Theme.lineSoft.cgColor
        addSubview(rightHairline)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = iconsColumn
        addSubview(scroll)

        sep.wantsLayer = true
        sep.layer?.backgroundColor = Theme.lineSoft.cgColor
        addSubview(sep)

        hint.onClick = { [weak self] in self?.onToggleIndex?() }
        addSubview(hint)

        footGlyph.font = Theme.mono(13, weight: .medium)
        footGlyph.textColor = Theme.agent
        addSubview(footGlyph)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `.on` = currently peeked OR pinned (crib-dock-index §1.4) — wider than
    /// the index row's peeked-only active state.
    func update(docs: [RestoreDoc], activePaths: Set<String>) {
        let paths = Set(docs.map(\.path))
        for (path, icon) in icons where !paths.contains(path) {
            icon.removeFromSuperview()
            icons[path] = nil
        }
        orderedPaths = docs.map(\.path)
        for doc in docs {
            let icon: DockIconView
            if let existing = icons[doc.path] {
                icon = existing
            } else {
                icon = DockIconView(path: doc.path)
                icon.onClick = { [weak self, path = doc.path] in self?.onPeek?(path) }
                icons[doc.path] = icon
                iconsColumn.addSubview(icon)
            }
            icon.apply(doc: doc, active: activePaths.contains(doc.path))
        }
        needsLayout = true
    }

    func pulse(_ path: String) {
        icons[path]?.restartPulse()
    }

    override func layout() {
        super.layout()
        rightHairline.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)

        let footSize = footGlyph.fittedSize
        let footTop = bounds.height - 10 - footSize.height
        footGlyph.frame = NSRect(
            x: ((bounds.width - footSize.width) / 2).rounded(),
            y: footTop,
            width: footSize.width,
            height: footSize.height
        )

        let hintBox = hint.frame.size
        let count = orderedPaths.count
        let iconsNeeded = count == 0 ? 0 : CGFloat(count) * 30 + CGFloat(count - 1) * 4
        // Below the icons: 4 gap + 6 margin + 1 sep + 6 margin + 4 gap + hint,
        // then the 4px column gap before the bottom-pinned foot.
        let fixedBelow = 4 + 6 + 1 + 6 + 4 + hintBox.height
        let iconsAvail = max(0, footTop - 4 - 10 - fixedBelow)
        let iconsHeight = min(iconsNeeded, iconsAvail)

        // 6px bleed on every side so pulse halos are not clipped by the clip view.
        scroll.frame = NSRect(x: 0, y: 10 - 6, width: bounds.width, height: iconsHeight + 12)
        iconsColumn.frame = NSRect(x: 0, y: 0, width: bounds.width, height: iconsNeeded + 12)
        for (i, path) in orderedPaths.enumerated() {
            icons[path]?.frame = NSRect(x: 8, y: 6 + CGFloat(i) * 34, width: 30, height: 30)
        }

        let sepY = 10 + iconsHeight + 4 + 6
        sep.frame = NSRect(x: ((bounds.width - 22) / 2).rounded(), y: sepY, width: 22, height: 1)

        hint.setFrameOrigin(NSPoint(
            x: ((bounds.width - hintBox.width) / 2).rounded(),
            y: sepY + 1 + 6 + 4
        ))
    }
}

@MainActor
final class FlippedColumnView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}
