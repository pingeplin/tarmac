import XCTest
@testable import TarmacKit

extension ThemeCatalog {
    /// The theme with that id. An id no theme has fails the test:
    /// `ThemeLibrary.entry` would give Breeze for it, and the test would go on.
    static func theme(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> Entry {
        guard let entry = all.first(where: { $0.id == id }) else {
            XCTFail("no theme \(id)", file: file, line: line)
            return all[0]
        }
        return entry
    }
}

extension Palette {
    /// A copy with the named members changed: what a case that breaks one
    /// rule starts from. `ansi` maps an index to its new colour.
    func changed(
        bg0: UInt32? = nil, bg1: UInt32? = nil, bg2: UInt32? = nil, text: UInt32? = nil, muted: UInt32? = nil,
        agent: UInt32? = nil, terminalForeground: UInt32? = nil, terminalBackground: UInt32? = nil,
        terminalSelection: UInt32? = nil, ansi: [Int: UInt32] = [:]
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
                cursor: terminal.cursor, selection: terminalSelection ?? terminal.selection,
                selectionAlpha: terminal.selectionAlpha,
                ansi: terminal.ansi.enumerated().map { ansi[$0.offset] ?? $0.element }
            )
        )
    }
}
