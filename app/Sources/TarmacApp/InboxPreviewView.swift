import AppKit
import TarmacKit

/// The inbox's preview pane (spec 2611.0018 D12–D14): the selected item's
/// kind tag, title, age and `go ↵`; its whole text as blocks between corner
/// quote marks, scrolling inside the pane; its place. A bell or an exit says
/// `no text`. It draws what it is given and reports `go ↵`.
@MainActor
final class InboxPreviewView: NSView {
    var onGo: (() -> Void)? {
        get { go.onClick }
        set { go.onClick = newValue }
    }

    private enum Metric {
        static let padTop: CGFloat = 8
        static let padX: CGFloat = 14
        static let padBottom: CGFloat = 10
        static let gap: CGFloat = 8
        /// Room for the corner quote marks on each side of the text.
        static let quoteRoom: CGFloat = 12
    }

    @MainActor
    private enum Font {
        static var title: NSFont { Theme.mono(10.5) }
        static var caption: NSFont { Theme.mono(10) }
        static var quote: NSFont { Theme.mono(11) }
    }

    private let kindTag = ChipView()
    private let title = OverlayLabel()
    private let age = OverlayLabel()
    private let go = InboxFilterButton(InboxCopy.go)
    private let caption = OverlayLabel()
    private let scroll = NSScrollView()
    private let doc = FlippedColumnView()
    private let text = MarkdownTextView()
    private let open = OverlayLabel()
    private let close = OverlayLabel()
    private let place = OverlayLabel()
    private var preview: InboxPreview?
    /// Set when the text changed: the next layout scrolls it to its top.
    private var scrollToTop = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for label in [title, place] { label.lineBreakMode = .byTruncatingTail }
        caption.maximumNumberOfLines = 0
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = doc
        for view in [text, open, close] { doc.addSubview(view) }
        for view in [kindTag, title, age, go, caption, scroll, place] { addSubview(view) }
        styleChanged()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        kindTag.apply(CardScale(zoom: 1, backing: window?.backingScaleFactor ?? 2))
    }

    /// A render that changes only the age keeps the text and its scroll.
    func render(_ preview: InboxPreview?) {
        let old = self.preview
        self.preview = preview
        draw(preview)
        if old?.id != preview?.id || old?.body != preview?.body {
            fillText()
            scrollToTop = true
        }
        needsLayout = true
    }

    /// A theme or a font change: the text is set again, where it was scrolled to.
    func styleChanged() {
        layer?.backgroundColor = Theme.bg1.cgColor
        go.setGoLook()
        let quote: [NSAttributedString.Key: Any] = [.font: Font.quote, .foregroundColor: Theme.faint]
        open.attributedStringValue = NSAttributedString(string: "“", attributes: quote)
        close.attributedStringValue = NSAttributedString(string: "”", attributes: quote)
        draw(preview)
        fillText()
        needsLayout = true
    }

    private func draw(_ preview: InboxPreview?) {
        let faint: [NSAttributedString.Key: Any] = [.font: Font.caption, .foregroundColor: Theme.faint]
        for view in [kindTag, title, age, go] { view.isHidden = preview == nil }
        place.isHidden = true
        caption.isHidden = true
        scroll.isHidden = true
        guard let preview else {
            caption.attributedStringValue = NSAttributedString(string: InboxCopy.nothingSelected, attributes: faint)
            caption.isHidden = false
            return
        }
        kindTag.setTone(.signal(preview.kind.signal, dimmed: false))
        kindTag.setLabel(preview.tag)
        title.attributedStringValue = NSAttributedString(
            string: preview.title, attributes: [.font: Font.title, .foregroundColor: Theme.text]
        )
        age.attributedStringValue = NSAttributedString(string: preview.age, attributes: faint)
        switch preview.body {
        case .noText:
            caption.attributedStringValue = NSAttributedString(
                string: InboxCopy.noText + "\n" + preview.place, attributes: faint
            )
            caption.isHidden = false
        case .blocks:
            place.attributedStringValue = NSAttributedString(string: preview.place, attributes: faint)
            place.isHidden = false
            scroll.isHidden = false
        }
    }

    /// The scroll position stays where it was unless `scrollToTop` is set.
    private func fillText() {
        if case .blocks(let blocks) = preview?.body { text.show(blocks) } else { text.show([]) }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let inner = width - Metric.padX * 2
        let tagSize = kindTag.intrinsicContentSize
        let titleSize = title.fittedSize
        let ageSize = age.fittedSize
        let goSize = go.fittingSize
        let line = max(tagSize.height, titleSize.height, goSize.height)
        kindTag.frame = NSRect(
            x: Metric.padX, y: line.centered(tagSize.height, top: Metric.padTop),
            width: tagSize.width, height: tagSize.height
        )
        go.frame = NSRect(
            x: width - Metric.padX - goSize.width, y: line.centered(goSize.height, top: Metric.padTop),
            width: goSize.width, height: goSize.height
        )
        age.frame = NSRect(
            x: go.frame.minX - Metric.gap - ageSize.width, y: line.centered(ageSize.height, top: Metric.padTop),
            width: ageSize.width, height: ageSize.height
        )
        let titleX = kindTag.frame.maxX + Metric.gap
        title.frame = NSRect(
            x: titleX, y: line.centered(titleSize.height, top: Metric.padTop),
            width: max(0, min(titleSize.width, age.frame.minX - Metric.gap - titleX)), height: titleSize.height
        )

        let top = preview == nil ? Metric.padTop : Metric.padTop + line + Metric.gap
        let captionSize = caption.fittedSize
        caption.frame = NSRect(
            x: Metric.padX, y: top,
            width: min(captionSize.width, inner), height: captionSize.height
        )
        let placeSize = place.fittedSize
        place.frame = NSRect(
            x: Metric.padX, y: bounds.height - Metric.padBottom - placeSize.height,
            width: min(placeSize.width, inner), height: placeSize.height
        )
        let bottom = place.isHidden ? bounds.height - Metric.padBottom : place.frame.minY - Metric.gap
        scroll.frame = NSRect(x: Metric.padX, y: top, width: inner, height: max(0, bottom - top))

        let textWidth = max(0, inner - Metric.quoteRoom * 2)
        let textHeight = text.fit(width: textWidth)
        let inset = MarkdownTextView.inset
        text.frame = NSRect(
            x: Metric.quoteRoom - inset.width, y: 0, width: textWidth + 2 * inset.width, height: textHeight
        )
        let openSize = open.fittedSize
        let closeSize = close.fittedSize
        open.frame = NSRect(x: 0, y: inset.height, width: openSize.width, height: openSize.height)
        close.frame = NSRect(
            x: inner - closeSize.width, y: max(0, textHeight - inset.height - closeSize.height),
            width: closeSize.width, height: closeSize.height
        )
        doc.frame = NSRect(x: 0, y: 0, width: inner, height: max(textHeight, scroll.contentSize.height))
        if scrollToTop {
            scrollToTop = false
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
