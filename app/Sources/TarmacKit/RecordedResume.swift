/// The command the app keeps for each terminal at a restore (2611.0015 D11);
/// a `term_resume` push is checked by `ResumeCommand.accepted` alone. Each
/// source is checked, so a value the app holds is one it would show and copy.
public enum RecordedResume {
    /// A first-visit restore: a cold spawn has the plan's command, which its
    /// record kept under the id it succeeds; a rebound term has its own record.
    public static func command(for term: BoardRestore.Term, termRecords: [String: TermRecord]) -> String? {
        ResumeCommand.accepted(term.needsSpawn ? term.resume : termRecords[term.termID]?.resume?.cmd)
    }
}
