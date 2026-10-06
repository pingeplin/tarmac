import AppKit
import TarmacKit

/// The two drawings of a theme in the Theme pane (spec 2610.0008): the
/// swatch of a row of the list, and the showcase's picture of a board.
///
/// Each is drawn from the theme's `Palette` and from nothing else. A system
/// colour would follow the app's appearance, and the picture of a light theme
/// must be the same while the app is dark.
@MainActor
enum ThemePicture {
    private static let swatchSize = NSSize(width: 22, height: 15)
    private static let showcaseSize = NSSize(width: 360, height: 224)
    private static let textSize: CGFloat = 10.5
    private static let lineHeight: CGFloat = 15
    private static let mono = NSFont.monospacedSystemFont(ofSize: textSize, weight: .regular)
    private static let headerHeight: CGFloat = 20
    private static let dot: CGFloat = 7

    /// The board, a card on it and one line of the card.
    static func swatch(_ palette: Palette) -> NSImage {
        NSImage(size: swatchSize, flipped: true) { bounds in
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).addClip()
            fill(bounds, palette.bg0)
            let card = NSRect(x: 4, y: 4, width: bounds.width - 8, height: bounds.height)
            fill(card, palette.terminal.background, radius: 2)
            fill(NSRect(x: 7, y: 8, width: 8, height: 2), palette.agent, radius: 1)
            // A board as light or as dark as the list would have no edge.
            Theme.srgb(palette.line).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            return true
        }
    }

    /// A board with a terminal card, a prime doc card and a status strip:
    /// each token where the app draws it.
    static func showcase(_ palette: Palette) -> NSImage {
        NSImage(size: showcaseSize, flipped: true) { bounds in
            fill(bounds, palette.bg0, radius: 8)
            let board = bounds.insetBy(dx: 10, dy: 10)
            let strip = NSRect(x: board.minX, y: board.maxY - 22, width: board.width, height: 22)
            let cards = NSRect(x: board.minX, y: board.minY, width: board.width, height: strip.minY - 8 - board.minY)
            let terminalWidth = ((cards.width - 8) * 1.45 / 2.45).rounded()
            drawTerminal(palette, in: NSRect(x: cards.minX, y: cards.minY, width: terminalWidth, height: cards.height))
            drawDoc(
                palette,
                in: NSRect(
                    x: cards.minX + terminalWidth + 8, y: cards.minY, width: cards.width - terminalWidth - 8,
                    height: cards.height
                )
            )
            drawStrip(palette, in: strip)
            return true
        }
    }

    private static func drawTerminal(_ palette: Palette, in rect: NSRect) {
        let terminal = palette.terminal
        let body = card(
            in: rect, fill: terminal.background, header: palette.bg2, rule: palette.lineSoft,
            dot: palette.repoColors[0], title: "zsh", titleColor: palette.muted
        )
        var line = NSPoint(x: body.minX + 7, y: body.minY + 6)
        text("$ make test", terminal.foreground, at: line)

        line.y += lineHeight
        let selected = "selected"
        let cell = NSAttributedString(string: "0", attributes: [.font: mono]).size().width
        let row = NSRect(x: line.x, y: line.y, width: cell * CGFloat(selected.count), height: lineHeight)
        Theme.srgb(terminal.selection, alpha: terminal.selectionAlpha).setFill()
        row.fill(using: .sourceOver)
        text(selected, terminal.foreground, at: line)
        fill(NSRect(x: row.maxX + cell, y: line.y, width: cell, height: lineHeight), terminal.cursor)

        for (index, color) in terminal.ansi.enumerated() {
            if index % 8 == 0 { line = NSPoint(x: body.minX + 7, y: line.y + lineHeight) }
            line.x = text(String(format: "%02d", index), color, at: line) + cell
        }
        border(rect, Theme.srgb(palette.line))
    }

    private static func drawDoc(_ palette: Palette, in rect: NSRect) {
        let page = card(
            in: rect, fill: palette.bg1, header: palette.primeHeaderBg, rule: palette.lineSoft,
            dot: palette.repoColors[2], title: "plan.md", titleColor: palette.text
        )
        var line = NSPoint(x: page.minX + 7, y: page.minY + 6)
        text("Heading", palette.text, .boldSystemFont(ofSize: textSize), at: line)

        line.y += lineHeight
        let prose = NSFont.systemFont(ofSize: textSize)
        var x = text("Prose with a ", palette.prose, prose, at: line)
        x = text("link", palette.agent, prose, at: NSPoint(x: x, y: line.y))
        text(".", palette.prose, prose, at: NSPoint(x: x, y: line.y))

        line.y += lineHeight + 4
        let code = NSRect(x: line.x, y: line.y, width: page.maxX - 7 - line.x, height: lineHeight + 12)
        fill(code, palette.terminal.background, radius: 3)
        text("code", palette.terminal.foreground, at: NSPoint(x: code.minX + 7, y: code.minY + 6))
        border(rect, Theme.srgb(palette.agent, alpha: 0.5))
    }

    private static func drawStrip(_ palette: Palette, in rect: NSRect) {
        fill(rect, palette.bg1, radius: 5)
        let line = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Theme.srgb(palette.lineSoft).setStroke()
        line.stroke()

        var point = NSPoint(x: rect.minX + 7, y: rect.minY + (rect.height - lineHeight) / 2)
        for (word, color) in [
            ("tarmac", palette.faint), ("● connected", palette.ok), ("● bell", palette.amber),
            ("error", palette.consoleError),
        ] {
            point.x = text(word, color, at: point) + 10
        }
        for (index, color) in palette.repoColors.reversed().enumerated() {
            let x = rect.maxX - 7 - dot - CGFloat(index) * (dot + 4)
            Theme.srgb(color).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
        }
    }

    /// A card's fill and header. Gives the room under the header.
    private static func card(
        in rect: NSRect, fill body: UInt32, header: UInt32, rule: UInt32, dot color: UInt32, title: String,
        titleColor: UInt32
    ) -> NSRect {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        fill(rect, body)
        let head = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
        fill(head, header)
        fill(NSRect(x: rect.minX, y: head.maxY, width: rect.width, height: 1), rule)
        NSGraphicsContext.restoreGraphicsState()

        Theme.srgb(color).setFill()
        NSBezierPath(ovalIn: NSRect(x: head.minX + 8, y: head.midY - dot / 2, width: dot, height: dot)).fill()
        text(title, titleColor, at: NSPoint(x: head.minX + 8 + dot + 5, y: head.minY + (headerHeight - lineHeight) / 2))
        return NSRect(x: rect.minX, y: head.maxY + 1, width: rect.width, height: rect.height - headerHeight - 1)
    }

    private static func border(_ rect: NSRect, _ color: NSColor) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
        path.lineWidth = 1.5
        color.setStroke()
        path.stroke()
    }

    private static func fill(_ rect: NSRect, _ color: UInt32, radius: CGFloat = 0) {
        Theme.srgb(color).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// Draws one line, its top at `point`. Gives the x where the line ends.
    @discardableResult
    private static func text(_ string: String, _ color: UInt32, _ font: NSFont = mono, at point: NSPoint) -> CGFloat {
        let line = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: Theme.srgb(color)])
        line.draw(at: NSPoint(x: point.x, y: point.y + (lineHeight - line.size().height) / 2))
        return point.x + line.size().width
    }
}
