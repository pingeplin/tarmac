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
