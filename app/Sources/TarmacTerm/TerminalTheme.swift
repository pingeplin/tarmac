import Foundation
import GhosttyVt

public struct RGB: Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(UInt8(hex >> 16 & 0xff), UInt8(hex >> 8 & 0xff), UInt8(hex & 0xff))
    }

    init(_ color: GhosttyColorRgb) {
        self.init(color.r, color.g, color.b)
    }

    var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }

    /// The WCAG 2 relative luminance, 0 (black) to 1 (white).
    var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

public struct TerminalTheme: Equatable, Sendable {
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    public var selection: RGB
    public var selectionAlpha: Double
    /// The 16 ANSI colours; indices 16–255 keep libghostty-vt's default cube and ramp.
    public var ansi: [RGB]

    public init(foreground: RGB, background: RGB, cursor: RGB, selection: RGB, selectionAlpha: Double, ansi: [RGB]) {
        precondition(ansi.count == 16, "a theme names exactly the 16 ANSI colours")
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.selectionAlpha = selectionAlpha
        self.ansi = ansi
    }

    public static let breeze = TerminalTheme(
        foreground: RGB(hex: 0xced2d6),
        background: RGB(hex: 0x31363b),
        cursor: RGB(hex: 0xeff0f1),
        selection: RGB(hex: 0x1abc9c),
        selectionAlpha: 0.3,
        ansi: [
            0x232627, 0xed1515, 0x11d116, 0xf67400, 0x1d99f3, 0x9b59b6, 0x1abc9c, 0xfcfcfc,
            0x7f8c8d, 0xc0392b, 0x1cdc9a, 0xfdbc4b, 0x3daee9, 0x8e44ad, 0x16a085, 0xffffff,
        ].map(RGB.init(hex:))
    )

    /// The background is darker than the foreground.
    public var isDark: Bool { background.luminance < foreground.luminance }
}

extension TerminalEngine {
    public func apply(_ theme: TerminalTheme) throws {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256)
        ghostty_color_palette_default(&palette)
        for (index, color) in theme.ansi.enumerated() { palette[index] = color.ghostty }
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette), "set palette")
        var foreground = theme.foreground.ghostty
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground), "set foreground")
        var background = theme.background.ghostty
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background), "set background")
        var cursor = theme.cursor.ghostty
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor), "set cursor")
        effects.isDark = theme.isDark
    }
}
