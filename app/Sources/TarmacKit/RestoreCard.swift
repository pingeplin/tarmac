/// The card over the board after a first-visit restore with cold spawns
/// (backlog §1.2, issue #358; its lines are 2611.0011 D13's, its choices
/// 2611.0015 D7–D8): what the restore brought back. With an agent session to
/// resume it offers three choices; without, any key but ⌘Q or a click closes
/// it. Its keys are decided by `KeyLadder`. A folder is counted as asked for,
/// not as found: a gone folder gives `$HOME` silently.
public struct RestoreCard: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// Nil for a line of plain words: no glyph means "resume" (2611.0015 D14).
        public let glyph: String?
        public let text: String
        public let ok: Bool

        public init(glyph: String?, text: String, ok: Bool) {
            self.glyph = glyph
            self.text = text
            self.ok = ok
        }

        public var string: String { glyph.map { "\($0) \(text)" } ?? text }
    }

    public struct Choice: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case resumeAll, perCard, skipAll }

        public let action: Action
        public let text: String
    }

    /// Shown only when the card has no choices.
    public static let footer = "any key to continue"

    public let lines: [Line]
    /// Empty unless some cold spawn has a resume command.
    public let choices: [Choice]

    /// Nil when no line has a count: a card that says nothing is not shown.
    public static func make(plan: BoardRestore.Plan) -> RestoreCard? {
        let spawned = plan.terms.filter(\.needsSpawn)
        let inFolders = spawned.filter { $0.spawn?.cwd != nil }.count
        let resumable = spawned.filter { $0.resume != nil }.count
        var lines: [Line] = []
        if inFolders == 1 { lines.append(Line(glyph: "✓", text: "1 terminal back in its folder", ok: true)) }
        if inFolders > 1 { lines.append(Line(glyph: "✓", text: "\(inFolders) terminals back in their folders", ok: true)) }
        if resumable > 0 {
            lines.append(Line(glyph: nil, text: "\(resumable) with an agent session to resume", ok: false))
        }
        guard !lines.isEmpty else { return nil }
        return RestoreCard(lines: lines, choices: resumable > 0 ? allChoices : [])
    }

    private static let allChoices = [
        Choice(action: .resumeAll, text: "⏎ resume all"),
        Choice(action: .perCard, text: "decide per card"),
        Choice(action: .skipAll, text: "esc skip all"),
    ]
}
