/// Which keys the app takes before the view with keyboard focus sees them, in
/// the order they are tried. The shell gathers the facts, asks, and performs
/// the action; what bytes a key sends once it reaches a terminal is the
/// terminal's business (`TermKeyBinding`).
public enum KeyLadder {
    /// Who holds keyboard focus.
    public enum Keys: Equatable, Sendable {
        /// A terminal card, live or dead.
        case terminal
        /// The board, or nothing: the app's own surface.
        case host
        /// The document of a borrowed HTML card.
        case document
        /// The console of an HTML card: text to select and copy, not to type in.
        case console
    }

    public struct Facts: Equatable, Sendable {
        /// The focused terminal has an IME composition in flight.
        public var composing: Bool
        public var switcherOpen: Bool
        public var keys: Keys
        /// The keys are being typed into a text control of a markdown doc's
        /// page: its raw HTML can hold an input or a textarea.
        public var editingText: Bool
        /// A signalling card is off screen, so Return has somewhere to fly.
        public var hasFlyTarget: Bool
        public var esc: EscLadder.Facts
        /// 2611.0011: what the focused terminal offers.
        public var offer: Offer
        /// The focused terminal ran its command by `.runResume`, and no key
        /// that is not a repeat has come since (`afterRun(was:press:action:)`).
        public var afterRun: Bool
        /// #358: the restore card's choices while it is up (2611.0015: none
        /// on a card with no resume line); nil while it is not.
        public var restoreCard: [RestoreCard.Choice.Action]?
        /// A key closed the restore card, and no key that is not a repeat has
        /// come since (`afterRestoreCard(was:press:action:)`).
        public var afterRestoreCard: Bool
        /// 2611.0013: the inbox panel is open.
        public var inboxOpen: Bool

        public init(
            composing: Bool = false, switcherOpen: Bool = false, keys: Keys = .terminal, editingText: Bool = false,
            hasFlyTarget: Bool = false, esc: EscLadder.Facts = EscLadder.Facts(), offer: Offer = .none,
            afterRun: Bool = false, restoreCard: [RestoreCard.Choice.Action]? = nil, afterRestoreCard: Bool = false,
            inboxOpen: Bool = false
        ) {
            self.composing = composing
            self.switcherOpen = switcherOpen
            self.keys = keys
            self.editingText = editingText
            self.hasFlyTarget = hasFlyTarget
            self.esc = esc
            self.offer = offer
            self.afterRun = afterRun
            self.restoreCard = restoreCard
            self.afterRestoreCard = afterRestoreCard
            self.inboxOpen = inboxOpen
        }
    }

    /// What the terminal with keyboard focus offers (2611.0011).
    public enum Offer: Equatable, Sendable {
        case none
        /// A resume offer that is not armed: the shell is not up, or the
        /// card is not prime.
        case resumeIdle
        /// A resume offer on the prime card whose shell is up.
        case resumeArmed
        /// A resume offer that runs at the card's first output (2611.0015 D1).
        case resumeQueued
        /// A dead card's offer to reopen.
        case reopen
        /// A reopen offer that does not take Return yet (#412): it is taken
        /// and dropped, so it reaches neither the dead card nor a fly.
        case reopenArming
    }

    public enum Action: Equatable, Sendable {
        /// Not the app's key: it goes on to the focused view and the menu.
        case passThrough
        /// ⌘K.
        case toggleSwitcher
        /// ⌘W: close the selected card, after closing an open switcher. Taken
        /// even with nothing selected, so it never reaches Close Window.
        case closeSelectedCard
        /// The open switcher owns the key (`SwitcherKeys`).
        case switcherKey
        /// ⌘T.
        case newTerminal
        /// Return: remember the viewport and fly to the offscreen signal.
        case flyToSignal
        case esc(EscLadder.Rung)
        /// The key is typing and the console holding the keyboard takes none:
        /// the keyboard goes back to where typing goes, and this key after it.
        case returnKeys
        /// Return on the prime terminal whose resume offer is armed.
        case runResume
        /// Return on a dead terminal that offers to reopen.
        case reopenDead
        /// A key taken and dropped: a repeat while an offer or the restore
        /// card shows or just after either acted, so a held key acts once, or
        /// a Return on a queued offer.
        case swallow
        /// A key on the restore card, which closes it and goes nowhere else:
        /// with choices a plain Return resumes all and a plain Esc skips all;
        /// any other key but ⌘Q decides per card.
        case restoreCard(RestoreCard.Choice.Action)
        /// ⌘I.
        case toggleInbox
        /// The open inbox panel owns the key (`InboxKeys`).
        case inboxKey
    }

    public static func decide(_ press: KeyPress, _ facts: Facts) -> Action {
        if let action = restoreCardAction(press, facts) { return action }
        // A sandboxed document's keys are its own: the web app's handler never
        // saw them either. ESC still un-borrows, through the card shim's relay.
        if facts.composing || facts.keys == .document { return .passThrough }
        if press.isCommandChord("k") { return .toggleSwitcher }
        if press.isCommandChord("i") { return .toggleInbox }
        if press.isCommandChord("w") { return .closeSelectedCard }
        if facts.switcherOpen { return .switcherKey }
        if facts.inboxOpen { return .inboxKey }
        if press.isCommandChord("t") { return .newTerminal }
        let plain = press.isUnmodifiedOrShifted
        if press.named == .enter, plain, facts.keys == .terminal, let offer = offerAction(press, facts) {
            return offer
        }
        let offTerminal = facts.keys == .host || facts.keys == .console
        if press.named == .enter, plain, offTerminal, !facts.editingText, facts.hasFlyTarget {
            return .flyToSignal
        }
        if press.named == .escape, let rung = EscLadder.rung(facts.esc) { return .esc(rung) }
        if facts.keys == .console, !selectsText(press) { return .returnKeys }
        return .passThrough
    }

    /// A plain Return on a terminal (2611.0011): a repeat is decided first, so
    /// a held key never runs or reopens again (the D10 amendment, RA3).
    private static func offerAction(_ press: KeyPress, _ facts: Facts) -> Action? {
        if press.isRepeat { return facts.offer != .none || facts.afterRun ? .swallow : nil }
        switch facts.offer {
        case .resumeArmed: return .runResume
        case .reopen: return .reopenDead
        // It means "run it", and it is already queued: passed on, it would
        // drop the run and give the shell an empty line (2611.0015 D2).
        case .resumeQueued, .reopenArming: return .swallow
        case .none, .resumeIdle: return nil
        }
    }

    /// The focused terminal's latch after `press` was decided as `action`:
    /// set by `.runResume`, kept by a repeat, cleared by any other key.
    public static func afterRun(was: Bool, press: KeyPress, action: Action) -> Bool {
        latch(was: was, press: press, setBy: action == .runResume)
    }

    /// The restore card (#358) comes before everything, the switcher and a
    /// composition too: it is drawn over them, and no key has reached a
    /// terminal since it showed. A repeat never closes it, so a key held from
    /// before it showed cannot close it unseen, and the repeats of the key
    /// that closed it are dropped. ⌘Q is the menu's.
    ///
    /// With choices (2611.0015 D7), a plain Return resumes all and a plain Esc
    /// skips all: the card comes before the Esc ladder, so a toast is not
    /// cleared first. Any other key decides per card.
    private static func restoreCardAction(_ press: KeyPress, _ facts: Facts) -> Action? {
        guard facts.restoreCard != nil || facts.afterRestoreCard, !press.isCommandChord("q") else { return nil }
        if press.isRepeat { return .swallow }
        guard let choices = facts.restoreCard else { return nil }
        let plain = press.isUnmodifiedOrShifted
        if !choices.isEmpty, plain, press.named == .enter { return .restoreCard(.resumeAll) }
        if !choices.isEmpty, plain, press.named == .escape { return .restoreCard(.skipAll) }
        return .restoreCard(.perCard)
    }

    /// The latch after `press` was decided as `action`: set by any of the
    /// restore card's choices, kept by a repeat, cleared by any other key. So
    /// no repeat of the key that chose reaches a terminal and drops its run.
    public static func afterRestoreCard(was: Bool, press: KeyPress, action: Action) -> Bool {
        if case .restoreCard = action { return true }
        return latch(was: was, press: press, setBy: false)
    }

    private static func latch(was: Bool, press: KeyPress, setBy: Bool) -> Bool {
        if setBy { return true }
        return press.isRepeat ? was : false
    }

    /// The keys a text that is only read still has a use for: a ⌘ chord —
    /// copy and select all are the menu's, sent to the text — and a shifted
    /// arrow, home, end or page key, which stretches the selection.
    private static func selectsText(_ press: KeyPress) -> Bool {
        press.command || (press.shift && movesTheCaret.contains(press.keyCode))
    }

    /// Left, right, down, up, home, end, page up, page down.
    private static let movesTheCaret: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
}
