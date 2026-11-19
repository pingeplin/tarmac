import AppKit
import TarmacKit

/// A report's text as blocks, wrapped (spec 2611.0018 D13). Not editable, not
/// selectable, never first responder and no click targets: the inbox panel
/// keeps the keys, and the text is a claim, not a page.
@MainActor
final class MarkdownTextView: NSTextView {
    private let boxes = CodeBoxLayoutManager()

    init() {
        let storage = NSTextStorage()
        storage.addLayoutManager(boxes)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        boxes.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textContainerInset = .zero
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ blocks: [MarkdownBlock]) {
        let style = MarkdownStyle()
        boxes.look = style.look
        textStorage?.setAttributedString(style.attributed(blocks))
    }

    /// The text's height at `width`, which the view takes.
    func fit(width: CGFloat) -> CGFloat {
        guard let container = textContainer else { return 0 }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        boxes.ensureLayout(for: container)
        return ceil(boxes.usedRect(for: container).height + MarkdownStyle.blockPadY)
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
    static let design: CGFloat = 11
    static let blockPadY = CodeBoxLayoutManager.blockPadY
    private static let blockPadX: CGFloat = 8
    private static let spanPad = CodeBoxLayoutManager.spanInset
    private static let listIndent: CGFloat = 18
    private static let blockGap: CGFloat = 7
    private static let itemGap: CGFloat = 2
    private static let obliqueness = 0.2

    let body = Theme.mono(design)
    let bold = Theme.mono(design, weight: .semibold)
    let italic: NSFont?
    let lineSpacing: CGFloat

    var look: CodeBoxLayoutManager.Look {
        CodeBoxLayoutManager.Look(spanFill: Theme.bg2, blockFill: Theme.bg0, border: Theme.line, lineSpacing: lineSpacing)
    }

    init() {
        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        self.italic = italic.fontDescriptor.symbolicTraits.contains(.italic) ? italic : nil
        lineSpacing = (Theme.chrome(Self.design) * 0.4).rounded()
    }

    func attributed(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            switch block {
            case .paragraph(let text):
                out.append(runs(text, color: Theme.muted, paragraph: paragraph(after: Self.blockGap)))
            case .heading(let text):
                out.append(runs(text, color: Theme.text, base: bold, paragraph: paragraph(after: Self.blockGap)))
            case .list(let items):
                for (number, item) in items.enumerated() {
                    let gap = number == items.count - 1 ? Self.blockGap : Self.itemGap
                    let style = paragraph(after: gap, indent: Theme.chrome(Self.listIndent))
                    out.append(NSAttributedString(
                        string: item.marker + "\t",
                        attributes: [.font: body, .foregroundColor: Theme.faint, .paragraphStyle: style]
                    ))
                    out.append(runs(item.text, color: Theme.muted, paragraph: style))
                    if number < items.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
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
        let room = 2 * Self.spanPad - 2
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: base ?? body, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            switch run.mark {
            case .bold: attributes[.font] = bold
            case .italic:
                if let italic { attributes[.font] = italic } else { attributes[.obliqueness] = Self.obliqueness }
            case .link: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .code:
                attributes[.codeSpan] = true
                if out.length > 0 { out.addAttribute(.kern, value: room, range: NSRange(location: out.length - 1, length: 1)) }
            case .plain, .bullet: break
            }
            let piece = NSMutableAttributedString(string: run.text, attributes: attributes)
            if run.mark == .code, piece.length > 0 {
                piece.addAttribute(.kern, value: room, range: NSRange(location: piece.length - 1, length: 1))
            }
            out.append(piece)
        }
        return out
    }
}

/// Draws the boxes an attributed string alone cannot: a rounded, bordered box
/// behind each line of a code span, and one full-width box behind a code
/// block (TextKit 1, checked in an offline spike). Not main-actor: AppKit
/// calls it as a plain `NSLayoutManager`, so it holds its colours itself.
private final class CodeBoxLayoutManager: NSLayoutManager {
    struct Look {
        let spanFill, blockFill, border: NSColor
        let lineSpacing: CGFloat
    }

    static let blockPadY: CGFloat = 6
    static let spanInset: CGFloat = 3.5

    var look: Look?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let look, let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for range in Self.ranges(of: .codeBlock, in: storage, within: chars) {
            var rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            rect.origin.x = 0
            rect.size.width = container.size.width
            rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -Self.blockPadY)
            Self.box(rect, radius: 4, fill: look.blockFill, border: look.border)
        }
        for range in Self.ranges(of: .codeSpan, in: storage, within: chars) {
            var rects: [NSRect] = []
            enumerateEnclosingRects(
                forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in rects.append(rect) }
            for rect in rects {
                var line = rect.offsetBy(dx: origin.x, dy: origin.y)
                line.origin.x -= Self.spanInset
                line.size.width += 2
                line.size.height -= look.lineSpacing
                Self.box(line, radius: 3, fill: look.spanFill, border: look.border)
            }
        }
    }

    private static func ranges(of key: NSAttributedString.Key, in storage: NSTextStorage, within: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        storage.enumerateAttribute(key, in: within) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    private static func box(_ rect: NSRect, radius: CGFloat, fill: NSColor, border: NSColor) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
