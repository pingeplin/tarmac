/// The `resume` chip in a live terminal card's header (spec 2611.0015 D12):
/// a click copies the recorded command and never runs it. A dead card has
/// none: its terminal is gone, and its reopen strip shows the command.
public enum ResumeHeaderChip {
    public struct Model: Equatable, Sendable {
        public let text: String
        /// The whole command, verbatim.
        public let toolTip: String
    }

    /// Nil for no command, a dead card, or a command `ResumeCommand.check`
    /// refuses: a copied command is pasted into a shell.
    public static func model(cmd: String?, dead: Bool) -> Model? {
        guard !dead, let cmd = ResumeCommand.accepted(cmd) else { return nil }
        return Model(text: "resume", toolTip: cmd)
    }

    public static let copiedToast = "resume command copied"
}

/// The command the app keeps for each terminal (2611.0015 D11), from the
/// restores and the `term_resume` pushes. Each source is checked, so a value
/// the app holds is one it would show and copy.
public enum RecordedResume {
    /// A first-visit restore: a cold spawn has the plan's command, which its
    /// record kept under the id it succeeds; a rebound term has its own record.
    public static func command(for term: BoardRestore.Term, termRecords: [String: TermRecord]) -> String? {
        guard term.needsSpawn else { return command(liveTermID: term.termID, termRecords: termRecords) }
        return ResumeCommand.accepted(term.resume)
    }

    public static func command(liveTermID: String, termRecords: [String: TermRecord]) -> String? {
        ResumeCommand.accepted(termRecords[liveTermID]?.resume?.cmd)
    }

    public static func command(pushed cmd: String?) -> String? {
        ResumeCommand.accepted(cmd)
    }
}
