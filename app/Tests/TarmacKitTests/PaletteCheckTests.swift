import XCTest

@testable import TarmacKit

/// 2610.0008: the detector. Each case that breaks a rule starts from Breeze
/// Light, which has no finding.
final class PaletteCheckTests: XCTestCase {
    private typealias Finding = PaletteCheck.Finding

    private let clean = ThemeCatalog.standard(for: .light).palette

    private func subjects(_ findings: [Finding]) -> [String] { findings.map(\.subject) }

    private func pairs(_ findings: [Finding]) -> [String] { findings.map { "\($0.subject) on \($0.ground)" } }

    /// "Terminal colour equal to background is a finding"
    func testAnANSIColourThatIsTheBackgroundIsOneTerminalFinding() {
        let findings = PaletteCheck.findings(clean.changed(ansi: [15: clean.terminal.background]))

        XCTAssertEqual(
            findings, [Finding(part: .terminal, subject: "ansi 15", ground: "background", ratio: 1, floor: 3)]
        )
    }

    /// "Foreground below seven to one is a finding" — the two sides of 7.
    func testAForegroundUnderSevenIsOneTerminalFinding() throws {
        let black = Dictionary(uniqueKeysWithValues: (0..<16).map { ($0, UInt32(0x000000)) })
        func findings(foreground: UInt32) -> [Finding] {
            PaletteCheck.findings(
                clean.changed(terminalForeground: foreground, terminalBackground: 0xffffff, ansi: black)
            )
        }

        let under = findings(foreground: 0x5a5a5a)
        XCTAssertEqual(under.count, 1)
        let finding = try XCTUnwrap(under.first)
        XCTAssertEqual(finding.part, .terminal)
        XCTAssertEqual(finding.subject, "foreground")
        XCTAssertEqual(finding.ground, "background")
        XCTAssertEqual(finding.floor, 7)
        XCTAssertEqual(finding.ratio, 6.90, accuracy: 0.01)
        XCTAssertEqual(findings(foreground: 0x595959), [])
    }

    /// "Muted under floor gives three findings" — the two sides of 4.5, on every fill.
    func testATextColourUnderFourAndAHalfIsAFindingOnEachFill() {
        let white = clean.changed(bg0: 0xffffff, bg1: 0xffffff, bg2: 0xffffff)

        let findings = PaletteCheck.findings(white.changed(muted: 0x777777))
        XCTAssertEqual(pairs(findings), ["muted on bg0", "muted on bg1", "muted on bg2"])
        XCTAssertEqual(findings.map(\.part), [.chrome, .chrome, .chrome])
        XCTAssertEqual(findings.map(\.floor), [4.5, 4.5, 4.5])
        XCTAssertEqual(PaletteCheck.findings(white.changed(muted: 0x767676)), [])
    }

    /// "Muted under floor gives three findings" — every subject on a fill, then the next fill.
    func testTheChromeFindingsGoFillByFill() {
        let palette = clean.changed(bg0: 0xffffff, bg1: 0xffffff, bg2: 0xffffff, text: 0x777777, muted: 0x777777)

        XCTAssertEqual(
            pairs(PaletteCheck.findings(palette)),
            ["text on bg0", "muted on bg0", "text on bg1", "muted on bg1", "text on bg2", "muted on bg2"]
        )
    }

    /// "Weak bg2 gives findings in fixed order"
    func testOnOneFillTheSubjectsComeInTokenOrderWithTheirFloors() {
        let findings = PaletteCheck.findings(clean.changed(bg2: 0x777777))

        XCTAssertEqual(Set(findings.map(\.ground)), ["bg2"])
        XCTAssertEqual(subjects(findings), ["text", "muted", "agent", "amber", "ok", "consoleError"])
        XCTAssertEqual(findings.map(\.floor), [4.5, 4.5, 3, 3, 3, 3])
    }

    /// "Mixed findings come in fixed order"
    func testTheANSIFindingsComeFirstThenTheForegroundThenTheChrome() {
        let background = clean.terminal.background
        let palette = clean.changed(
            agent: clean.bg0, terminalForeground: 0x808080, ansi: [3: background, 9: background]
        )

        XCTAssertEqual(
            pairs(PaletteCheck.findings(palette)),
            [
                "ansi 3 on background", "ansi 9 on background", "foreground on background", "agent on bg0",
                "agent on bg1", "agent on bg2",
            ]
        )
    }

    /// "No catalog theme has a chrome finding" — the chrome is Tarmac's own choice in every theme.
    func testNoThemeHasAChromeFinding() {
        for entry in ThemeCatalog.all {
            XCTAssertEqual(pairs(PaletteCheck.findings(entry.palette).filter { $0.part == .chrome }), [], entry.id)
        }
    }

    /// "Breeze Light and GitHub Light have no finding"
    func testBreezeLightAndGitHubLightHaveNoFinding() {
        for id in ["breeze-light", "github-light"] {
            XCTAssertEqual(pairs(PaletteCheck.findings(ThemeCatalog.theme(id).palette)), [], id)
        }
    }

    /// "Terminal findings match the findings table" — the upstream terminal colours are kept as they are, so these
    /// are the pairs a user of the theme cannot read well.
    func testTheTerminalFindingsOfEveryThemeAreThoseOfTheSpec() {
        let expected: [String: [String]] = [
            "breeze-light": [],
            "breeze-dark": ["ansi 0", "ansi 1", "ansi 5", "ansi 9", "ansi 13"],
            "catppuccin-latte": [
                "ansi 0", "ansi 2", "ansi 3", "ansi 5", "ansi 8", "ansi 10", "ansi 11", "ansi 13", "ansi 14",
            ],
            "catppuccin-mocha": ["ansi 0", "ansi 8"],
            "github-light": [],
            "github-dark": ["ansi 0"],
            "solarized-light": [
                "ansi 2", "ansi 3", "ansi 6", "ansi 7", "ansi 12", "ansi 14", "ansi 15", "foreground",
            ],
            "solarized-dark": ["ansi 0", "ansi 8", "ansi 10", "foreground"],
        ]

        XCTAssertEqual(Set(ThemeCatalog.all.map(\.id)), Set(expected.keys))
        for entry in ThemeCatalog.all {
            let terminal = PaletteCheck.findings(entry.palette).filter { $0.part == .terminal }
            XCTAssertEqual(subjects(terminal), expected[entry.id], entry.id)
        }
    }

    /// "Terminal findings match the findings table"
    func testSolarizedLightsBrightWhiteIsItsBackground() throws {
        let findings = PaletteCheck.findings(ThemeCatalog.theme("solarized-light").palette)

        XCTAssertEqual(try XCTUnwrap(findings.first { $0.subject == "ansi 15" }).ratio, 1)
    }
}
