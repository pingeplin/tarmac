@testable import TarmacKit

extension Palette {
    /// A copy with the named members changed: what a case that breaks one
    /// rule starts from. `ansi` maps an index to its new colour.
    func changed(
        bg0: UInt32? = nil, bg1: UInt32? = nil, bg2: UInt32? = nil, text: UInt32? = nil, muted: UInt32? = nil,
        agent: UInt32? = nil, terminalForeground: UInt32? = nil, terminalBackground: UInt32? = nil,
        ansi: [Int: UInt32] = [:]
    ) -> Palette {
        Palette(
            bg0: bg0 ?? self.bg0, bg1: bg1 ?? self.bg1, bg2: bg2 ?? self.bg2, bg3: bg3,
            line: line, lineSoft: lineSoft, liftBorder: liftBorder, primeHeaderBg: primeHeaderBg,
            text: text ?? self.text, muted: muted ?? self.muted, faint: faint, prose: prose,
            agent: agent ?? self.agent, amber: amber, ok: ok, consoleError: consoleError,
            scrollThumb: scrollThumb, scrollThumbLine: scrollThumbLine, repoColors: repoColors,
            terminal: Terminal(
                foreground: terminalForeground ?? terminal.foreground,
                background: terminalBackground ?? terminal.background,
                cursor: terminal.cursor, selection: terminal.selection, selectionAlpha: terminal.selectionAlpha,
                ansi: terminal.ansi.enumerated().map { ansi[$0.offset] ?? $0.element }
            )
        )
    }
}
