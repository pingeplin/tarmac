/// What a dead card offers when its board's latest restore kept a record of
/// it (spec 2611.0011, D10, D11): reopen in place, in its folder, and then
/// offer its resume command.
public enum DeadCardOffer {
    public struct Offer: Equatable, Sendable {
        public let cwd: String?
        /// A command `ResumeCommand.check` accepts, or nil.
        public let resume: String?
        /// The strip's lines: `reopen here  ⏎`, then the folder and the
        /// command when there is one.
        public let lines: [String]
    }

    /// Nil unless the record has a folder or an accepted command.
    public static func make(record: TermRecord?, home: String) -> Offer? {
        let cwd = record?.lastCwd
        let resume = ResumeCommand.accepted(record?.resume?.cmd)
        guard cwd != nil || resume != nil else { return nil }
        var lines = ["reopen here  ⏎"]
        if let cwd { lines.append("in \(ChromeText.tilde(cwd, home: home))") }
        if let resume { lines.append("then offers: \(ResumeCommandDisplay.display(resume))") }
        return Offer(cwd: cwd, resume: resume, lines: lines)
    }

    /// The spawn that replaces the dead card. It succeeds the dead id: without
    /// it the record would stay under that id with no owner.
    public static func reopen(_ offer: Offer, deadID: String) -> (spawn: SpawnRequest, resume: String?) {
        (SpawnRequest(cwd: offer.cwd, succeeds: deadID), offer.resume)
    }
}
