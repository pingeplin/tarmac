import AppKit
import QuartzCore
import TarmacKit

/// kbd chip per crib: mono 500 10px muted, bg2, 1px line border with a 2px
/// bottom edge, radius 4, padding 1px 5px. With an onClick it is a button
/// (hover bg3 + text color); without one it is display-only, as in M0.
final class KbdChipView: NSView {
    var onClick: (() -> Void)?

    private let label: NSTextField
    private let size: NSSize
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        label.font = Theme.mono(10, weight: .medium)
        label.textColor = Theme.muted
        let textSize = label.intrinsicContentSize
        size = NSSize(width: textSize.width + 10, height: textSize.height + 3)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4

        let bottomEdge = NSView(frame: NSRect(x: 1, y: 0, width: size.width - 2, height: 1))
        bottomEdge.wantsLayer = true
        bottomEdge.layer?.backgroundColor = Theme.line.cgColor
        bottomEdge.autoresizingMask = [.width]
        addSubview(bottomEdge)

        label.frame = NSRect(x: 5, y: 2, width: textSize.width, height: textSize.height)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { size }

    // Display-only chips stay click-through; buttons capture clicks on children too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil else { return nil }
        return super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) {
        guard onClick != nil else { return }
        layer?.backgroundColor = Theme.bg3.cgColor
        label.textColor = Theme.text
    }

    override func mouseExited(with event: NSEvent) {
        guard onClick != nil else { return }
        layer?.backgroundColor = Theme.bg2.cgColor
        label.textColor = Theme.muted
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
        if onClick != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

@MainActor
final class PeekPanel: NSView {
    var onPin: (() -> Void)?
    var onClose: (() -> Void)?

    private let header = NSView()
    private let repoDot = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    // Honest meta per crib-state §3.1: agent cyan @0.85, header font, M1 = time part only.
    private let meta = RecentMetaLabel(font: Theme.mono(11), color: Theme.agent.withAlphaComponent(0.85))
    private let pinChip = KbdChipView("⌘⏎ pin")
    private let escChip = KbdChipView("esc")
    private let leftBorder = NSView()
    private let headerHairline = NSView()
    private let docView = DocWebView()

    private(set) var currentPath: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowOffset = NSSize(width: -26, height: 0)
        shadow.shadowBlurRadius = 30
        self.shadow = shadow

        leftBorder.wantsLayer = true
        leftBorder.layer?.backgroundColor = Theme.line.cgColor
        addSubview(leftBorder)

        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bg2.cgColor
        addSubview(header)

        headerHairline.wantsLayer = true
        headerHairline.layer?.backgroundColor = Theme.lineSoft.cgColor
        header.addSubview(headerHairline)

        repoDot.wantsLayer = true
        repoDot.layer?.cornerRadius = 3.5
        header.addSubview(repoDot)

        pathLabel.font = Theme.mono(11)
        pathLabel.textColor = Theme.muted
        pathLabel.lineBreakMode = .byTruncatingHead
        header.addSubview(pathLabel)

        meta.onUpdate = { [weak self] in self?.needsLayout = true }
        header.addSubview(meta)

        pinChip.onClick = { [weak self] in self?.onPin?() }
        header.addSubview(pinChip)
        escChip.onClick = { [weak self] in self?.onClose?() }
        header.addSubview(escChip)

        addSubview(docView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        leftBorder.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        header.frame = NSRect(x: 1, y: 0, width: bounds.width - 1, height: 36)
        docView.frame = NSRect(x: 1, y: 36, width: bounds.width - 1, height: max(0, bounds.height - 36))

        let hh = header.bounds.height
        headerHairline.frame = NSRect(x: 0, y: 0, width: header.bounds.width, height: 1)
        repoDot.frame = NSRect(x: 12, y: (hh - 7) / 2, width: 7, height: 7)
        let escSize = escChip.intrinsicContentSize
        escChip.frame = NSRect(
            x: header.bounds.width - 12 - escSize.width,
            y: (hh - escSize.height) / 2,
            width: escSize.width,
            height: escSize.height
        )
        let pinSize = pinChip.intrinsicContentSize
        pinChip.frame = NSRect(
            x: escChip.frame.minX - 6 - pinSize.width,
            y: (hh - pinSize.height) / 2,
            width: pinSize.width,
            height: pinSize.height
        )
        let labelHeight = pathLabel.intrinsicContentSize.height
        let labelX: CGFloat = 12 + 7 + 8
        var labelMax = pinChip.frame.minX - 8
        if !meta.isHidden {
            labelMax -= meta.frame.width + 8
        }
        pathLabel.frame = NSRect(
            x: labelX,
            y: (hh - labelHeight) / 2,
            width: max(0, min(pathLabel.fittedSize.width, labelMax - labelX)),
            height: labelHeight
        )
        if !meta.isHidden {
            meta.setFrameOrigin(NSPoint(x: pathLabel.frame.maxX + 8, y: ((hh - meta.frame.height) / 2).rounded()))
        }
    }

    func present(path: String, doc: RestoreDoc?, markdown: String) {
        currentPath = path
        if let doc {
            pathLabel.stringValue = doc.displayPath
            repoDot.layer?.backgroundColor =
                Theme.repoColor(index: doc.repoColor, fallbackName: doc.displayRepoName).cgColor
            meta.setChanged(doc.lastChangedMs)
        } else {
            // M0 fallback for paths the registry does not know.
            let home = NSHomeDirectory()
            pathLabel.stringValue = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            let repoKey = (path as NSString).deletingLastPathComponent
            repoDot.layer?.backgroundColor = Theme.repoColor(for: (repoKey as NSString).lastPathComponent).cgColor
            meta.setChanged(nil)
        }
        needsLayout = true
        docView.render(markdown: markdown)
    }
}
