import AppKit
import TarmacKit

/// One index item row (crib-dock-index §2.3–2.4): basename label, then unread
/// 5px / recent 7px agent dots. `.on` = currently peeked only.
@MainActor
final class IndexItemRow: NSView {
    let path: String
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let unreadDot = NSView()
    private let recentDot = NSView()
    private var hovered = false
    private var active = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    init(path: String, label text: String, toolTip: String, unread: Bool, recent: Bool, active: Bool, width: CGFloat) {
        self.path = path
        self.active = active
        let labelHeight = NSTextField(labelWithString: text).intrinsicContentSize.height
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: labelHeight + 8))
        wantsLayer = true
        layer?.cornerRadius = 5
        self.toolTip = toolTip

        label.stringValue = text
        label.font = Theme.mono(11)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 2.5
        unreadDot.layer?.backgroundColor = Theme.agent.cgColor
        unreadDot.isHidden = !unread
        addSubview(unreadDot)

        recentDot.wantsLayer = true
        recentDot.layer?.cornerRadius = 3.5
        recentDot.layer?.backgroundColor = Theme.agent.cgColor
        recentDot.isHidden = !recent
        addSubview(recentDot)

        var dotsWidth: CGFloat = 0
        if unread { dotsWidth += 7 + 5 }
        if recent { dotsWidth += 7 + 7 }
        let labelWidth = min(label.intrinsicContentSize.width, width - 22 - 8 - dotsWidth)
        label.frame = NSRect(x: 22, y: 4, width: max(0, labelWidth), height: labelHeight)
        var x = label.frame.maxX + 7
        if unread {
            unreadDot.frame = NSRect(x: x, y: ((bounds.height - 5) / 2).rounded(), width: 5, height: 5)
            x += 5 + 7
        }
        if recent {
            recentDot.frame = NSRect(x: x, y: ((bounds.height - 7) / 2).rounded(), width: 7, height: 7)
        }
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
            label.textColor = Theme.text
        } else if hovered {
            layer?.backgroundColor = Theme.bg3.cgColor
            label.textColor = Theme.muted
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = Theme.muted
        }
    }
}

/// The 224px index (crib §2): caps row, repo groups, `⏎ peek · ⌘⏎ pin` hints,
/// strip footer. Replaces the dock wholesale; no expand animation.
@MainActor
final class IndexView: NSView {
    var onPeek: ((String) -> Void)?
    var onToggleIndex: (() -> Void)?

    private let rightHairline = NSView()
    private let caps = ClickTargetView()
    private let capsLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let groupsColumn = FlippedColumnView()
    private let hintsLabel = NSTextField(labelWithString: "⏎ peek · ⌘⏎ pin")
    private let foot = FlippedColumnView()
    private let footBorder = NSView()
    private let footGlyph = NSTextField(labelWithString: "▞")

    private var docs: [RestoreDoc] = []
    private var activePath: String?
    private var groupsHeight: CGFloat = 0
    private var expiryWork: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor

        rightHairline.wantsLayer = true
        rightHairline.layer?.backgroundColor = Theme.lineSoft.cgColor
        addSubview(rightHairline)

        capsLabel.attributedStringValue = NSAttributedString(
            string: "OPEN DOCS · ⌘E",
            attributes: [
                .font: Theme.mono(9.5, weight: .medium),
                .foregroundColor: Theme.faint,
                .kern: 9.5 * 0.12,
            ]
        )
        caps.addSubview(capsLabel)
        caps.onClick = { [weak self] in self?.onToggleIndex?() }
        addSubview(caps)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = groupsColumn
        addSubview(scroll)

        hintsLabel.font = Theme.mono(10)
        hintsLabel.textColor = Theme.faint
        addSubview(hintsLabel)

        footBorder.wantsLayer = true
        footBorder.layer?.backgroundColor = Theme.lineSoft.cgColor
        foot.addSubview(footBorder)
        footGlyph.font = Theme.mono(11, weight: .medium)
        footGlyph.textColor = Theme.agent
        foot.addSubview(footGlyph)
        addSubview(foot)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(docs: [RestoreDoc], activePath: String?) {
        self.docs = docs
        self.activePath = activePath
        rebuild()
    }

    private func rebuild() {
        expiryWork?.cancel()
        groupsColumn.subviews.forEach { $0.removeFromSuperview() }

        let width: CGFloat = 224 - 16
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var nextExpiryMs: UInt64?
        var y: CGFloat = 0

        for group in DocStore.groups(of: docs) {
            let header = FlippedColumnView()
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = Theme.repoColor(index: group.colorIndex, fallbackName: group.name).cgColor
            let name = NSTextField(labelWithString: group.name)
            name.font = Theme.mono(10.5, weight: .medium)
            name.textColor = Theme.muted
            let nameSize = name.intrinsicContentSize
            header.frame = NSRect(x: 0, y: y, width: width, height: nameSize.height + 8)
            dot.frame = NSRect(x: 8, y: ((header.bounds.height - 7) / 2).rounded(), width: 7, height: 7)
            name.frame = NSRect(x: 8 + 7 + 7, y: 4, width: min(nameSize.width, width - 30), height: nameSize.height)
            header.addSubview(dot)
            header.addSubview(name)
            groupsColumn.addSubview(header)
            y += header.bounds.height

            let labels = DocStore.itemLabels(for: group)
            for (doc, label) in zip(group.docs, labels) {
                let recent = DocStore.isRecent(lastChangedMs: doc.lastChangedMs, nowMs: nowMs)
                if recent, let changed = doc.lastChangedMs {
                    let expiry = changed + DocStore.recentWindowMs
                    nextExpiryMs = min(nextExpiryMs ?? expiry, expiry)
                }
                let row = IndexItemRow(
                    path: doc.path,
                    label: label,
                    toolTip: doc.displayPath,
                    unread: !doc.read,
                    recent: recent,
                    active: doc.path == activePath,
                    width: width
                )
                row.onClick = { [weak self, path = doc.path] in self?.onPeek?(path) }
                row.setFrameOrigin(NSPoint(x: 0, y: y))
                groupsColumn.addSubview(row)
                y += row.bounds.height
            }
            y += 10
        }

        groupsHeight = max(0, y - 10)
        needsLayout = true

        // The static recent dot outlives the halo; drop it when the 30s window
        // closes (crib §2.4).
        if let expiry = nextExpiryMs, expiry > nowMs {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            }
            expiryWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(expiry - nowMs) / 1000 + 0.05,
                execute: work
            )
        }
    }

    override func layout() {
        super.layout()
        rightHairline.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)

        let width = bounds.width - 16
        let capsSize = capsLabel.intrinsicContentSize
        caps.frame = NSRect(x: 8, y: 10, width: width, height: capsSize.height + 12)
        capsLabel.frame = NSRect(x: 8, y: 4, width: min(capsSize.width, width - 16), height: capsSize.height)

        let glyphSize = footGlyph.intrinsicContentSize
        let footHeight = 1 + 7 + glyphSize.height + 7
        foot.frame = NSRect(x: 8, y: bounds.height - 10 - footHeight, width: width, height: footHeight)
        footBorder.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        footGlyph.frame = NSRect(x: 8, y: 1 + 7, width: glyphSize.width, height: glyphSize.height)

        let hintsSize = hintsLabel.intrinsicContentSize
        let hintsHeight = hintsSize.height + 12
        let avail = max(0, foot.frame.minY - hintsHeight - caps.frame.maxY)
        let scrollHeight = min(groupsHeight, avail)
        scroll.frame = NSRect(x: 8, y: caps.frame.maxY, width: width, height: scrollHeight)
        groupsColumn.frame = NSRect(x: 0, y: 0, width: width, height: groupsHeight)
        hintsLabel.frame = NSRect(
            x: 16,
            y: caps.frame.maxY + scrollHeight + 6,
            width: min(hintsSize.width, width - 16),
            height: hintsSize.height
        )
    }
}
