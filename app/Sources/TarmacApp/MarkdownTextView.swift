import AppKit
import TarmacKit

/// A report's text as blocks, wrapped (spec 2611.0018 D13). Not editable, not
/// selectable, never first responder and no click targets: the inbox panel
/// keeps the keys, and the text is a claim, not a page.
@MainActor
final class MarkdownTextView: NSTextView {
    private let boxes = CodeBoxLayoutManager()
    /// The width `fit` last laid the text out at, and the height it found.
    private var fitted: (width: CGFloat, height: CGFloat)?

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
        fitted = nil
    }

    /// The text's height at `width`, which the view takes. A layout pass with
    /// the same width and text lays nothing out again.
    func fit(width: CGFloat) -> CGFloat {
        if let fitted, fitted.width == width { return fitted.height }
        guard let container = textContainer else { return 0 }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        boxes.ensureLayout(for: container)
        let height = ceil(boxes.usedRect(for: container).height + CodeBoxLayoutManager.blockPadY)
        fitted = (width, height)
        return height
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
    private static let blockPadY = CodeBoxLayoutManager.blockPadY
    private static let blockPadX: CGFloat = 8
    private static let listIndent: CGFloat = 18
    private static let markerGap: CGFloat = 6
    private static let blockGap: CGFloat = 7
    private static let itemGap: CGFloat = 2

    private let marks = MarkFaces(design: design)
    private let lineSpacing = (Theme.chrome(design) * 0.4).rounded()
    private var body: NSFont { marks.base }

    var look: CodeBoxLayoutManager.Look {
        CodeBoxLayoutManager.Look(spanFill: Theme.bg2, blockFill: Theme.bg0, border: Theme.line, lineSpacing: lineSpacing)
    }

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
        func makeRoom() {
            guard out.length > 0 else { return }
            out.addAttribute(.kern, value: 2 * CodeBoxLayoutManager.spanInset - 2, range: NSRange(location: out.length - 1, length: 1))
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
            CodeBox.draw(rect, radius: 4, fill: look.blockFill, border: look.border)
        }
        for range in Self.ranges(of: .codeSpan, in: storage, within: chars) {
            // Line by line, by the glyphs: an enclosing rect runs to the end of
            // a line the span wraps on.
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var pieces: [NSRange] = []
            enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
                let piece = NSIntersectionRange(line, glyphs)
                if piece.length > 0 { pieces.append(piece) }
            }
            for rect in pieces.map({ boundingRect(forGlyphRange: $0, in: container) }) {
                var line = rect.offsetBy(dx: origin.x, dy: origin.y)
                line.origin.x -= Self.spanInset
                line.size.width += 2
                line.size.height -= look.lineSpacing
                CodeBox.draw(line, radius: 3, fill: look.spanFill, border: look.border)
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
}
