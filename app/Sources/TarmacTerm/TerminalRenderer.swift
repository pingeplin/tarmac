import CoreGraphics
import CoreText
import Foundation

enum CursorDisplay: Equatable {
    case hidden
    case focused
    /// The view is not first responder: an outline, so it never reads as "typing lands here".
    case unfocused
}

extension RGB {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    func blended(with other: RGB, alpha: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) * (1 - alpha) + Double(b) * alpha).rounded())
        }
        return RGB(mix(r, other.r), mix(g, other.g), mix(b, other.b))
    }
}

/// Draws `TerminalFrame` rows with CoreText into a top-down context. Layout is
/// in points; every fill is snapped to the context's device pixels, so the grid
/// stays seamless at any board zoom and glyphs are rasterised at the real scale
/// instead of being upscaled.
@MainActor
final class TerminalRenderer {
    let fonts: TerminalFonts
    var theme: TerminalTheme

    private enum Shape {
        case glyph(CGGlyph)
        case line(CTLine)
    }

    private struct ShapeKey: Hashable {
        let text: String
        let style: UInt8
    }

    private var shapes: [ShapeKey: Shape] = [:]

    init(fonts: TerminalFonts, theme: TerminalTheme) {
        self.fonts = fonts
        self.theme = theme
    }

    func draw(
        _ frame: TerminalFrame,
        rows: Range<Int>,
        layout: TerminalGridLayout,
        cursor: CursorDisplay,
        preedit: String? = nil,
        in context: CGContext
    ) {
        let pixels = PixelGrid(context)
        context.saveGState()
        defer { context.restoreGState() }

        for row in rows.clamped(to: 0..<frame.rows.count) {
            drawBackgrounds(frame, row: row, layout: layout, pixels: pixels, in: context)
            drawText(frame, row: row, layout: layout, pixels: pixels, in: context)
        }
        if let position = frame.cursor, rows.contains(position.row) {
            drawCursor(position, frame: frame, layout: layout, display: cursor, pixels: pixels, in: context)
            if let preedit, !preedit.isEmpty {
                drawPreedit(preedit, at: position, frame: frame, layout: layout, pixels: pixels, in: context)
            }
        }
    }

    // MARK: colours

    private func colours(_ cell: FrameCell, frame: TerminalFrame) -> (foreground: RGB, background: RGB) {
        var foreground = cell.style.foreground ?? frame.foreground
        var background = cell.style.background ?? frame.background
        if cell.style.flags.contains(.inverse) { swap(&foreground, &background) }
        if cell.style.flags.contains(.faint) { foreground = background.blended(with: foreground, alpha: 0.5) }
        return (foreground, background)
    }

    // MARK: backgrounds

    private func drawBackgrounds(
        _ frame: TerminalFrame, row: Int, layout: TerminalGridLayout, pixels: PixelGrid, in context: CGContext
    ) {
        let cells = frame.rows[row].cells
        let selection = frame.rows[row].selection
        var start = 0
        while start < cells.count {
            let colour = background(cells[start], selected: selection?.contains(start) == true, frame: frame)
            var end = start + 1
            while end < cells.count,
                  background(cells[end], selected: selection?.contains(end) == true, frame: frame) == colour {
                end += 1
            }
            context.setFillColor(colour.cgColor)
            context.fill(pixels.snap(layout.rect(col: start, row: row, span: end - start)))
            start = end
        }
    }

    private func background(_ cell: FrameCell, selected: Bool, frame: TerminalFrame) -> RGB {
        let base = colours(cell, frame: frame).background
        return selected ? base.blended(with: theme.selection, alpha: theme.selectionAlpha) : base
    }

    // MARK: text

    private func drawText(
        _ frame: TerminalFrame, row: Int, layout: TerminalGridLayout, pixels: PixelGrid, in context: CGContext
    ) {
        let metrics = fonts.metrics
        for (col, cell) in frame.rows[row].cells.enumerated() where cell.width != .spacer {
            let flags = cell.style.flags
            let foreground = colours(cell, frame: frame).foreground
            let origin = layout.rect(col: col, row: row).origin
            let span = cell.width == .wide ? 2 : 1

            if !cell.text.isEmpty, cell.text != " ", !flags.contains(.invisible) {
                draw(cell.text, flags: flags, colour: foreground, at: origin, pixels: pixels, in: context)
            }
            let decoration = cell.style.underlineColor ?? foreground
            if cell.style.underline != .none {
                drawRule(cell.style.underline, y: origin.y + metrics.underlineOffset, x: origin.x,
                         span: span, layout: layout, colour: decoration, pixels: pixels, in: context)
            }
            if flags.contains(.strikethrough) {
                drawRule(.single, y: origin.y + metrics.strikethroughOffset, x: origin.x,
                         span: span, layout: layout, colour: foreground, pixels: pixels, in: context)
            }
            if flags.contains(.overline) {
                drawRule(.single, y: origin.y, x: origin.x,
                         span: span, layout: layout, colour: foreground, pixels: pixels, in: context)
            }
        }
    }

    private func draw(
        _ text: String, flags: CellFlags, colour: RGB, at origin: CGPoint, pixels: PixelGrid, in context: CGContext
    ) {
        let font = fonts.font(for: flags)
        let baseline = CGPoint(x: pixels.snap(origin.x), y: pixels.snap(origin.y + fonts.metrics.baseline))
        context.setFillColor(colour.cgColor)
        // Drawing a line leaves its position in the text matrix, so start from the bare flip.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        switch shape(text, font: font, style: flags.intersection([.bold, .italic]).rawValue) {
        case .glyph(var glyph):
            // Glyph positions are in text space, which the flipped text matrix mirrors.
            var position = CGPoint(x: baseline.x, y: -baseline.y)
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        case .line(let line):
            context.textPosition = baseline
            CTLineDraw(line, context)
        }
    }

    /// One glyph of the terminal face when it has the character; otherwise a
    /// CoreText line, which brings font fallback (CJK, emoji) and cluster shaping.
    private func shape(_ text: String, font: CTFont, style: UInt8) -> Shape {
        let key = ShapeKey(text: text, style: style)
        if let cached = shapes[key] { return cached }

        var shape: Shape
        let units = Array(text.utf16)
        var glyph = CGGlyph(0)
        if units.count == 1, CTFontGetGlyphsForCharacters(font, units, &glyph, 1) {
            shape = .glyph(glyph)
        } else {
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorFromContextAttributeName: true,
            ]
            let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
            shape = .line(CTLineCreateWithAttributedString(string))
        }
        shapes[key] = shape
        return shape
    }

    private func drawRule(
        _ style: UnderlineStyle, y: CGFloat, x: CGFloat, span: Int, layout: TerminalGridLayout,
        colour: RGB, pixels: PixelGrid, in context: CGContext
    ) {
        let thickness = max(pixels.snap(fonts.metrics.lineThickness), pixels.pixel)
        let width = layout.cell.width * CGFloat(span)
        let top = pixels.snap(y)
        context.setFillColor(colour.cgColor)
        func rule(_ offset: CGFloat) {
            context.fill(CGRect(x: pixels.snap(x), y: top + offset, width: pixels.snap(x + width) - pixels.snap(x), height: thickness))
        }
        switch style {
        case .none:
            break
        case .single, .curly:
            rule(0)
        case .double:
            rule(-thickness)
            rule(thickness)
        case .dotted, .dashed:
            let dash = style == .dotted ? thickness : layout.cell.width / 3
            var offset: CGFloat = 0
            while offset < width {
                context.fill(CGRect(x: pixels.snap(x + offset), y: top, width: min(dash, width - offset), height: thickness))
                offset += dash * 2
            }
        }
    }

    // MARK: cursor

    private func drawCursor(
        _ cursor: FrameCursor, frame: TerminalFrame, layout: TerminalGridLayout,
        display: CursorDisplay, pixels: PixelGrid, in context: CGContext
    ) {
        guard display != .hidden else { return }
        let col = cursor.onWideTail ? cursor.col - 1 : cursor.col
        guard frame.rows.indices.contains(cursor.row), frame.rows[cursor.row].cells.indices.contains(col) else { return }
        let cell = frame.rows[cursor.row].cells[col]
        let rect = pixels.snap(layout.rect(col: col, row: cursor.row, span: cell.width == .wide ? 2 : 1))
        let colour = frame.cursorColor ?? theme.cursor
        let stroke = max(pixels.snap(1), pixels.pixel)
        context.setFillColor(colour.cgColor)

        guard display == .focused else {
            context.setStrokeColor(colour.cgColor)
            context.setLineWidth(stroke)
            context.stroke(rect.insetBy(dx: stroke / 2, dy: stroke / 2))
            return
        }
        switch cursor.shape {
        case .block:
            context.fill(rect)
            if !cell.text.isEmpty, cell.text != " " {
                draw(cell.text, flags: cell.style.flags, colour: colours(cell, frame: frame).background,
                     at: rect.origin, pixels: pixels, in: context)
            }
        case .hollowBlock:
            context.setStrokeColor(colour.cgColor)
            context.setLineWidth(stroke)
            context.stroke(rect.insetBy(dx: stroke / 2, dy: stroke / 2))
        case .bar:
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: max(pixels.snap(1.5), pixels.pixel), height: rect.height))
        case .underline:
            let height = max(pixels.snap(2), pixels.pixel)
            context.fill(CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height))
        }
    }

    /// The IME's uncommitted text, drawn over the grid from the cursor and underlined.
    private func drawPreedit(
        _ text: String, at cursor: FrameCursor, frame: TerminalFrame, layout: TerminalGridLayout,
        pixels: PixelGrid, in context: CGContext
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: fonts.regular,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        )
        let origin = layout.rect(col: cursor.col, row: cursor.row).origin
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let box = pixels.snap(CGRect(x: origin.x, y: origin.y, width: width, height: layout.cell.height))
        context.setFillColor(frame.background.cgColor)
        context.fill(box)
        context.setFillColor(frame.foreground.cgColor)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: box.minX, y: pixels.snap(origin.y + fonts.metrics.baseline))
        CTLineDraw(line, context)
        let thickness = max(pixels.snap(fonts.metrics.lineThickness), pixels.pixel)
        context.fill(CGRect(x: box.minX, y: box.maxY - thickness, width: box.width, height: thickness))
    }
}

/// Snaps point coordinates onto the context's device pixel grid.
private struct PixelGrid {
    let scale: CGFloat

    init(_ context: CGContext) {
        let transform = context.ctm
        scale = max(abs(transform.a) > 0 ? abs(transform.a) : abs(transform.b), 0.01)
    }

    var pixel: CGFloat { 1 / scale }

    func snap(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    func snap(_ rect: CGRect) -> CGRect {
        let minX = snap(rect.minX), minY = snap(rect.minY)
        return CGRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
    }
}
