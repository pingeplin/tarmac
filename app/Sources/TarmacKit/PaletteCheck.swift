/// The detector (spec 2610.0008): the pairs of a palette that have less
/// contrast than their floor. It reads nothing but the palette, and refuses
/// and changes nothing: a theme whose terminal colours come from upstream
/// ships with its findings.
public enum PaletteCheck {
    public struct Finding: Equatable, Sendable {
        public enum Part: Sendable { case terminal, chrome }

        public let part: Part
        /// `ansi 0` to `ansi 15`, `foreground`, or a chrome token's name.
        public let subject: String
        /// `background`, or the name of a chrome fill.
        public let ground: String
        public let ratio: Double
        public let floor: Double
    }

    /// The floor of a chrome text and of a chrome mark on a fill. A theme
    /// from a file derives its chrome to these (`ThemeFile.palette(from:)`).
    static let textFloor = 4.5
    static let markFloor = 3.0

    private struct Subject {
        let name: String
        let colour: UInt32
        let floor: Double
    }

    /// The ANSI colours by index, then the foreground, then the chrome: every
    /// subject on one fill before the next fill.
    public static func findings(_ palette: Palette) -> [Finding] {
        let terminal = palette.terminal
        let printed =
            terminal.ansi.enumerated().map { Subject(name: "ansi \($0.offset)", colour: $0.element, floor: 3) }
            + [Subject(name: "foreground", colour: terminal.foreground, floor: 7)]
        let chrome = [
            Subject(name: "text", colour: palette.text, floor: textFloor),
            Subject(name: "muted", colour: palette.muted, floor: textFloor),
            Subject(name: "agent", colour: palette.agent, floor: markFloor),
            Subject(name: "amber", colour: palette.amber, floor: markFloor),
            Subject(name: "ok", colour: palette.ok, floor: markFloor),
            Subject(name: "consoleError", colour: palette.consoleError, floor: markFloor),
        ]
        let fills = [("bg0", palette.bg0), ("bg1", palette.bg1), ("bg2", palette.bg2)]
        return under(.terminal, printed, on: "background", terminal.background)
            + fills.flatMap { under(.chrome, chrome, on: $0.0, $0.1) }
    }

    /// A ratio equal to its floor is no finding.
    private static func under(
        _ part: Finding.Part, _ subjects: [Subject], on ground: String, _ colour: UInt32
    ) -> [Finding] {
        subjects.compactMap { subject in
            let ratio = Contrast.ratio(subject.colour, colour)
            guard ratio < subject.floor else { return nil }
            return Finding(part: part, subject: subject.name, ground: ground, ratio: ratio, floor: subject.floor)
        }
    }
}
