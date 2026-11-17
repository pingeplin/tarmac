import Foundation

/// What a dead card offers (spec 2611.0011, D10, D11): reopen in place, in its
/// folder, and then offer its resume command.
public enum DeadCardOffer {
    public struct Offer: Equatable, Sendable {
        /// The folder the reopen asks for; nil leaves it to the daemon, which
        /// starts in the record of the id it succeeds.
        public let cwd: String?
        /// A command `ResumeCommand.check` accepts, or nil.
        public let resume: String?
        /// The strip's lines: `reopen here  ⏎`, then the folder and the
        /// command when there is one.
        public let lines: [String]
    }

    /// How long after its exit a card that ended in this run takes Return
    /// (#412): a stray Return keeps the failure on screen. A press on the
    /// strip is a deliberate click and works at once.
    public static let returnArmDelay: TimeInterval = 1

    /// Nil unless the record has a folder or an accepted command.
    public static func make(record: TermRecord?, home: String) -> Offer? {
        let cwd = record?.lastCwd
        let resume = ResumeCommand.accepted(record?.resume?.cmd)
        guard cwd != nil || resume != nil else { return nil }
        return Offer(cwd: cwd, resume: resume, lines: lines(cwd: cwd, resume: resume, home: home))
    }

    /// A card that ended in this run (`endedHere`, #412) is always offered, at
    /// its exit and at every later restore. Its strip shows `lastCwd`, the
    /// freshest folder the app knows (a restore corrects it), but the reopen
    /// asks for none: the daemon's record of the dead id is at least as fresh.
    /// No command: the daemon dropped it at the terminal's end (D3), whatever
    /// an older restore recorded. Any other card is offered its record.
    public static func make(record: TermRecord?, endedHere: Bool, lastCwd: String?, home: String) -> Offer? {
        guard endedHere else { return make(record: record, home: home) }
        return Offer(cwd: nil, resume: nil, lines: lines(cwd: lastCwd, resume: nil, home: home))
    }

    /// What Return on the dead card does (`KeyLadder.Offer`): a card that
    /// ended at `endedAt` reopens only `returnArmDelay` after it.
    public static func returnKey(endedAt: Date?, now: Date) -> KeyLadder.Offer {
        guard let endedAt, now.timeIntervalSince(endedAt) < returnArmDelay else { return .reopen }
        return .reopenArming
    }

    private static func lines(cwd: String?, resume: String?, home: String) -> [String] {
        var lines = ["reopen here  ⏎"]
        if let cwd { lines.append("in \(ChromeText.tilde(cwd, home: home))") }
        if let resume { lines.append("then offers: \(ResumeCommandDisplay.display(resume))") }
        return lines
    }

    /// The spawn that replaces the dead card. It succeeds the dead id: without
    /// it the record would stay under that id with no owner.
    public static func reopen(_ offer: Offer, deadID: String) -> (spawn: SpawnRequest, resume: String?) {
        (SpawnRequest(cwd: offer.cwd, succeeds: deadID), offer.resume)
    }
}
