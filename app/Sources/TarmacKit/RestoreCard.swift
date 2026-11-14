/// The card over the board after a first-visit restore with cold spawns
/// (backlog §1.2, issue #358; its lines are 2611.0011 D13's): what the restore
/// brought back, until any key but ⌘Q or a click closes it. Its keys are
/// decided by `KeyLadder`. A folder is counted as asked for, not as found: a
/// gone folder gives `$HOME` silently.
public struct RestoreCard: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let glyph: String
        public let text: String
        public let ok: Bool

        public init(glyph: String, text: String, ok: Bool) {
            self.glyph = glyph
            self.text = text
            self.ok = ok
        }

        public var string: String { "\(glyph) \(text)" }
    }

    public static let footer = "any key to continue"

    public let lines: [Line]

    /// Nil when no line has a count: a card that says nothing is not shown.
    public static func make(plan: BoardRestore.Plan) -> RestoreCard? {
        let spawned = plan.terms.filter(\.needsSpawn)
        let inFolders = spawned.filter { $0.spawn?.cwd != nil }.count
        let resumable = spawned.filter { $0.resume != nil }.count
        var lines: [Line] = []
        if inFolders == 1 { lines.append(Line(glyph: "✓", text: "1 terminal back in its folder", ok: true)) }
        if inFolders > 1 { lines.append(Line(glyph: "✓", text: "\(inFolders) terminals back in their folders", ok: true)) }
        if resumable > 0 {
            lines.append(Line(glyph: "↻", text: "\(resumable) with an agent session to resume", ok: false))
        }
        return lines.isEmpty ? nil : RestoreCard(lines: lines)
    }
}
