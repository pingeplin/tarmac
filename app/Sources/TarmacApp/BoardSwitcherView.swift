import AppKit
import QuartzCore
import TarmacKit

/// A switcher row's render inputs: the pure view-model row (display, meta, glyph
/// flags) plus the board's tile projection items for the thumbnail. Built by
/// `AppController` from each board's live state.
struct SwitcherRowVM {
    let row: BoardSwitcher.BoardRow
    /// World rects + signal for the 86×54 thumbnail (a board's `minimapItems`,
    /// readable even while the board is backgrounded).
    let thumb: [Minimap.Item]
}

/// The ⌘K boards switcher overlay (M3 P4, design ref board-v4.jsx B5 +
/// board.css `.tm-boards`/`.tm-veil`/`.tm-bthumb`). A modal veil over the board
/// hosting a centered 540px panel: a header (`▞ boards — type to filter`), a
/// scrollable list of board rows (thumbnail · `▞ name` · meta counts), and a
/// footer of key hints. **Render-only** — the view holds no selection/filter
/// logic; `AppController` drives it via `render(...)` (state in `BoardSwitcher`,
/// the unit-tested view-model) and handles all keys through the global key
/// monitor (the established chrome pattern, as for ⌥tab / ⌘T). Clicks on a row
/// fire `onPickRow`; a click on the veil fires `onDismiss`.
@MainActor
final class BoardSwitcherView: NSView {
    /// A row was clicked (its index among the visible rows).
    var onPickRow: ((Int) -> Void)?
    /// The veil (outside the panel) was clicked.
    var onDismiss: (() -> Void)?

    static let panelWidth: CGFloat = 540
    static let panelTop: CGFloat = 72
    private static let headerH: CGFloat = 41
    private static let footerH: CGFloat = 37
    static let rowH: CGFloat = 76
    // Keep the panel clear of the status bar when there are many boards.
    private static let bottomMargin: CGFloat = 56

    private let panel = FlippedBox()
    private let headerLabel = NSTextField(labelWithString: "")
    private let headerSep = NSView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let footerSep = NSView()
    private let scroll = NSScrollView()
    private let rowsDoc = FlippedBox()
    private var rowViews: [BoardSwitcherRow] = []
    private var selected = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Veil (board.css `.tm-veil`: rgba(8,10,13,0.62)) — darkens the board behind.
        layer?.backgroundColor = NSColor(srgbRed: 8 / 255, green: 10 / 255, blue: 13 / 255, alpha: 0.62).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.bg2.cgColor
        panel.layer?.borderColor = Theme.line.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.cornerRadius = 12
        // Keep the drop shadow (board.css `box-shadow: 0 24px 60px rgba(0,0,0,0.6)`).
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -24)
        shadow.shadowBlurRadius = 60
        panel.shadow = shadow
        addSubview(panel)

        headerLabel.font = Theme.mono(12)
        headerLabel.drawsBackground = false
        headerLabel.isBezeled = false
        panel.addSubview(headerLabel)

        headerSep.wantsLayer = true
        headerSep.layer?.backgroundColor = Theme.lineSoft.cgColor
        panel.addSubview(headerSep)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = rowsDoc
        panel.addSubview(scroll)

        footerSep.wantsLayer = true
        footerSep.layer?.backgroundColor = Theme.lineSoft.cgColor
        panel.addSubview(footerSep)

        footerLabel.font = Theme.mono(10)
        footerLabel.textColor = Theme.faint
        footerLabel.drawsBackground = false
        footerLabel.isBezeled = false
        footerLabel.stringValue = "⏎ open board      ⌘1-9 jump      n new board"
        panel.addSubview(footerLabel)

        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setVisible(_ on: Bool) { isHidden = !on }

    /// Rebuilds the panel from the visible rows, the keyboard selection, and the
    /// current filter query, then scrolls the selection into view.
    func render(rows: [SwitcherRowVM], selected: Int, query: String) {
        self.selected = selected
        headerLabel.attributedStringValue = headerAttr(query: query)

        for v in rowViews { v.removeFromSuperview() }
        rowViews = rows.enumerated().map { idx, vm in
            let r = BoardSwitcherRow()
            r.configure(vm: vm, selected: idx == selected)
            r.onClick = { [weak self] in self?.onPickRow?(idx) }
            rowsDoc.addSubview(r)
            return r
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if rowViews.indices.contains(selected) {
            rowViews[selected].scrollToVisible(rowViews[selected].bounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A click outside the panel dismisses (the veil is modal but tap-to-close).
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { onDismiss?() }
    }

    override func layout() {
        super.layout()
        let totalRows = CGFloat(rowViews.count) * Self.rowH
        let maxRows = max(Self.rowH, bounds.height - Self.panelTop - Self.headerH - Self.footerH - Self.bottomMargin)
        let rowsAreaH = min(totalRows, maxRows).rounded()
        let panelH = Self.headerH + rowsAreaH + Self.footerH
        let px = ((bounds.width - Self.panelWidth) / 2).rounded()
        panel.frame = NSRect(x: px, y: Self.panelTop, width: Self.panelWidth, height: panelH)

        // Header (band 0..headerH), label inset 16, vertically centered.
        headerLabel.sizeToFit()
        let hh = headerLabel.frame.height
        headerLabel.frame = NSRect(x: 16, y: ((Self.headerH - hh) / 2).rounded(), width: Self.panelWidth - 32, height: hh)
        headerSep.frame = NSRect(x: 0, y: Self.headerH - 1, width: Self.panelWidth, height: 1)

        scroll.frame = NSRect(x: 0, y: Self.headerH, width: Self.panelWidth, height: rowsAreaH)
        rowsDoc.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: totalRows)
        for (idx, r) in rowViews.enumerated() {
            r.frame = NSRect(x: 0, y: CGFloat(idx) * Self.rowH, width: Self.panelWidth, height: Self.rowH)
        }

        footerSep.frame = NSRect(x: 0, y: Self.headerH + rowsAreaH, width: Self.panelWidth, height: 1)
        footerLabel.sizeToFit()
        let fh = footerLabel.frame.height
        footerLabel.frame = NSRect(x: 16, y: Self.headerH + rowsAreaH + ((Self.footerH - fh) / 2).rounded(), width: Self.panelWidth - 32, height: fh)
    }

    private func headerAttr(query: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let faint: [NSAttributedString.Key: Any] = [.font: Theme.mono(12), .foregroundColor: Theme.faint]
        let textc: [NSAttributedString.Key: Any] = [.font: Theme.mono(12), .foregroundColor: Theme.text]
        s.append(NSAttributedString(string: "▞ ", attributes: faint))
        s.append(NSAttributedString(string: "boards", attributes: textc))
        if query.isEmpty {
            s.append(NSAttributedString(string: "  — type to filter", attributes: [.font: Theme.mono(12), .foregroundColor: Theme.faint.withAlphaComponent(0.6)]))
        } else {
            s.append(NSAttributedString(string: "  · \(query)", attributes: textc))
        }
        return s
    }
}

/// One switcher row (board.css `.tm-brow`): thumbnail · `▞ name` · meta counts,
/// `.on` (selected) painted bg3 with the name in `text`. Clicking it opens that
/// board.
@MainActor
final class BoardSwitcherRow: NSView {
    var onClick: (() -> Void)?

    private let thumb = BoardThumbView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for label in [nameLabel, metaLabel] {
            label.drawsBackground = false
            label.isBezeled = false
            label.isEditable = false
        }
        addSubview(thumb)
        addSubview(nameLabel)
        addSubview(metaLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(vm: SwitcherRowVM, selected: Bool) {
        layer?.backgroundColor = (selected ? Theme.bg3 : NSColor.clear).cgColor
        thumb.setItems(vm.thumb)

        // Name: `▞` glyph (cyan when live, else faint) + display name (text when
        // selected, else muted).
        let glyphColor = vm.row.isLive ? Theme.agent : Theme.faint
        let nameColor = selected ? Theme.text : Theme.muted
        let nameFont = Theme.mono(12, weight: .medium)
        let n = NSMutableAttributedString()
        n.append(NSAttributedString(string: "▞ ", attributes: [.font: nameFont, .foregroundColor: glyphColor]))
        n.append(NSAttributedString(string: vm.row.display, attributes: [.font: nameFont, .foregroundColor: nameColor]))
        nameLabel.attributedStringValue = n

        // Meta: leading ⠧ spinner (agent) when running, then the faint count line.
        let metaFont = Theme.mono(10)
        let m = NSMutableAttributedString()
        if vm.row.running > 0 {
            m.append(NSAttributedString(string: "⠧ ", attributes: [.font: metaFont, .foregroundColor: Theme.agent]))
        }
        m.append(NSAttributedString(string: vm.row.meta, attributes: [.font: metaFont, .foregroundColor: Theme.faint]))
        metaLabel.attributedStringValue = m

        needsLayout = true
    }

    override func layout() {
        super.layout()
        thumb.frame = NSRect(x: 16, y: ((bounds.height - BoardThumbView.size.height) / 2).rounded(),
                             width: BoardThumbView.size.width, height: BoardThumbView.size.height)
        let nameX = 16 + BoardThumbView.size.width + 13
        nameLabel.sizeToFit()
        let nh = nameLabel.frame.height
        nameLabel.frame = NSRect(x: nameX, y: ((bounds.height - nh) / 2).rounded(), width: nameLabel.frame.width, height: nh)
        metaLabel.sizeToFit()
        let mw = metaLabel.frame.width
        let mh = metaLabel.frame.height
        metaLabel.frame = NSRect(x: bounds.width - 16 - mw, y: ((bounds.height - mh) / 2).rounded(), width: mw, height: mh)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The 86×54 board thumbnail (board.css `.tm-bthumb`): a static mini-projection
/// of the board's tile world-frames into the box, colored by signal (cyan live,
/// amber bell, neutral). Reuses `BoardWayfinding`'s world→box mapping (the same
/// projection the minimap uses) — NOT live views. Empty boards render just the
/// dot grid.
@MainActor
final class BoardThumbView: NSView {
    static let size = NSSize(width: 86, height: 54)
    private static let pad: CGFloat = 5

    private var items: [Minimap.Item] = []

    override var isFlipped: Bool { true }
    // Clicks belong to the enclosing row, not the thumbnail.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setItems(_ items: [Minimap.Item]) {
        self.items = items
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Faint dot grid (board.css `.tm-bthumb` radial 9px lattice).
        Theme.line.withAlphaComponent(0.35).setFill()
        let step: CGFloat = 9
        var y = step / 2
        while y < bounds.height {
            var x = step / 2
            while x < bounds.width {
                NSBezierPath(ovalIn: NSRect(x: x - 0.4, y: y - 0.4, width: 0.8, height: 0.8)).fill()
                x += step
            }
            y += step
        }
        // Projected tiles.
        guard let box = BoardWayfinding.boundingBox(of: items.map(\.worldRect)) else { return }
        let mapping = BoardWayfinding.minimapMapping(worldBox: box, minimapSize: bounds.size, pad: Self.pad)
        for item in items {
            let r = mapping.toMinimap(item.worldRect)
            let color: NSColor
            switch item.signal {
            case .live: color = Theme.agent.withAlphaComponent(0.55)
            case .bell: color = Theme.amber.withAlphaComponent(0.7)
            case .none: color = Theme.bg3
            }
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// A plain top-down (flipped) container, so panel + row-list math is y-down like
/// the rest of the chrome.
@MainActor
private final class FlippedBox: NSView {
    override var isFlipped: Bool { true }
}
