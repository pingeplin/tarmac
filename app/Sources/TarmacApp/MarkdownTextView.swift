import AppKit
import TarmacKit

/// A report's text as blocks, wrapped (spec 2611.0018 D13). Not editable, not
/// selectable, never first responder and no click targets: the inbox panel
/// keeps the keys, and the text is a claim, not a page. It draws the boxes an
/// attributed string alone cannot: a rounded, bordered box behind each line of
/// a code span, and one full-width box behind a code block. They are drawn by
/// the view, not the layout manager: `NSTextView` clips a layout manager's
/// background to the lines it draws, which cut off a box that reaches past them.
@MainActor
final class MarkdownTextView: NSTextView {
    static let blockPadY: CGFloat = 6
    /// Room around the text for the code boxes, which reach past the glyphs.
    static let inset = NSSize(width: CodeSpanBox.padding.rounded(.up), height: blockPadY)

    private var style: MarkdownStyle?
    /// The width `fit` last laid the text out at, and the height it found.
    private var fitted: (width: CGFloat, height: CGFloat)?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textContainerInset = Self.inset
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ blocks: [MarkdownBlock]) {
        let style = MarkdownStyle()
        self.style = style
        textStorage?.setAttributedString(style.attributed(blocks))
        fitted = nil
    }

    /// The view's height for text `width` wide, insets included. A layout pass
    /// with the same width and text lays nothing out again.
    func fit(width: CGFloat) -> CGFloat {
        if let fitted, fitted.width == width { return fitted.height }
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height + 2 * Self.inset.height)
        fitted = (width, height)
        return height
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let style, let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let all = NSRange(location: 0, length: storage.length)
        func glyphs(_ range: NSRange) -> NSRange { layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil) }
        storage.enumerateAttribute(.codeBlock, in: all) { value, range, _ in
            guard value != nil else { return }
            var box = layout.boundingRect(forGlyphRange: glyphs(range), in: container)
            box.origin.x = 0
            box.size.width = container.size.width
            box = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -Self.blockPadY)
            CodeBox.draw(Self.whole(box), radius: 4, fill: Theme.bg0, border: Theme.line)
        }
        storage.enumerateAttribute(.codeSpan, in: all) { value, range, _ in
            guard value != nil else { return }
            // Line by line, by the glyphs: an enclosing rect runs to the end of
            // a line the span wraps on.
            let span = glyphs(range)
            layout.enumerateLineFragments(forGlyphRange: span) { fragment, _, _, line, _ in
                let piece = NSIntersectionRange(line, span)
                guard piece.length > 0 else { return }
                let box = CodeSpanBox.rect(
                    glyphs: layout.boundingRect(forGlyphRange: piece, in: container),
                    baseline: fragment.minY + layout.location(forGlyphAt: piece.location).y, face: style.codeFace
                ).offsetBy(dx: origin.x, dy: origin.y)
                CodeBox.draw(
                    self.backingAlignedRect(box, options: .alignAllEdgesNearest), radius: 3,
                    fill: Theme.bg0, border: Theme.line
                )
            }
        }
    }

    /// On whole points, so a 1 px border is sharp on a 1× display too.
    private static func whole(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
    }
}

extension NSAttributedString.Key {
    fileprivate static let codeSpan = NSAttributedString.Key("TarmacCodeSpan")
    fileprivate static let codeBlock = NSAttributedString.Key("TarmacCodeBlock")
}

/// The pane's fonts, colours and spacing, read from the theme and the
/// Interface size in effect when it is made.
@MainActor
private struct MarkdownStyle {
    private static let design: CGFloat = 11
    private static let blockPadY = MarkdownTextView.blockPadY
    private static let blockPadX: CGFloat = 8
    private static let listIndent: CGFloat = 18
    private static let markerGap: CGFloat = 6
    private static let blockGap: CGFloat = 7
    private static let itemGap: CGFloat = 2

    private let marks: MarkFaces
    private let lineSpacing = (Theme.chrome(design) * 0.4).rounded()
    let codeFace: CodeSpanBox.Face

    init() {
        marks = MarkFaces(design: Self.design)
        codeFace = marks.codeFace()
    }

    private var body: NSFont { marks.base }

    func attributed(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            switch block {
            case .paragraph(let text):
                out.append(runs(text, color: Theme.muted, paragraph: paragraph(after: Self.blockGap)))
            case .heading(let text):
                out.append(runs(text, color: Theme.text, base: marks.bold, paragraph: paragraph(after: Self.blockGap)))
            case .list(let items):
                // A marker wider than the indent, as `10.`, would tab to the next stop.
                let longest = items.map(\.marker).max { $0.count < $1.count } ?? ""
                let widest = NSAttributedString(string: longest, attributes: [.font: body]).size().width
                let indent = max(Theme.chrome(Self.listIndent), (widest + Theme.chrome(Self.markerGap)).rounded(.up))
                for (number, item) in items.enumerated() {
                    let gap = number == items.count - 1 ? Self.blockGap : Self.itemGap
                    let style = paragraph(after: gap, indent: indent)
                    out.append(NSAttributedString(
                        string: item.marker + "\t",
                        attributes: [.font: body, .foregroundColor: Theme.faint, .paragraphStyle: style]
                    ))
                    out.append(runs(item.text, color: Theme.muted, paragraph: style))
                    if number < items.count - 1 {
                        out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: style]))
                    }
                }
            case .code(let lines):
                let style = paragraph(after: Self.blockGap + Self.blockPadY, inset: Self.blockPadX)
                style.paragraphSpacingBefore = Self.blockPadY + (index == 0 ? 0 : Self.blockPadY)
                out.append(NSAttributedString(
                    string: lines.joined(separator: "\u{2028}"),
                    attributes: [.font: body, .foregroundColor: Theme.text, .paragraphStyle: style, .codeBlock: true]
                ))
            }
            if !last { out.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
        }
        return out
    }

    private func paragraph(after: CGFloat, indent: CGFloat = 0, inset: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = Theme.chrome(after)
        style.headIndent = indent + inset
        style.firstLineHeadIndent = inset
        style.tailIndent = -inset
        if indent > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
        return style
    }

    /// A code span gets room for its box as kern: on the character before it
    /// and on its own last character.
    private func runs(
        _ text: InlineText, color: NSColor, base: NSFont? = nil, paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func makeRoom() {
            guard out.length > 0 else { return }
            out.addAttribute(.kern, value: CodeSpanBox.kern, range: NSRange(location: out.length - 1, length: 1))
        }
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: base ?? body, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            attributes.merge(marks.attributes(for: run.mark)) { $1 }
            if run.mark == .code {
                attributes[.codeSpan] = true
                makeRoom()
            }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
            if run.mark == .code { makeRoom() }
        }
        return out
    }
}
