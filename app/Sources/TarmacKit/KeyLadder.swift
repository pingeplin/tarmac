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
        /// #358: the restore card is up.
        public var restoreCard: Bool
        /// A key closed the restore card, and no key that is not a repeat has
        /// come since (`afterRestoreCard(was:press:action:)`).
        public var afterRestoreCard: Bool

        public init(
            composing: Bool = false, switcherOpen: Bool = false, keys: Keys = .terminal, editingText: Bool = false,
            hasFlyTarget: Bool = false, esc: EscLadder.Facts = EscLadder.Facts(), offer: Offer = .none,
            afterRun: Bool = false, restoreCard: Bool = false, afterRestoreCard: Bool = false
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
        /// A dead card's offer to reopen.
        case reopen
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
        /// A repeated Return while an offer shows, or just after a run: taken
        /// and dropped, so a held key acts once.
        case ignoreRepeat
        /// Any key but ⌘Q while the restore card is up: it closes the card
        /// and goes nowhere else.
        case closeRestoreCard
    }

    public static func decide(_ press: KeyPress, _ facts: Facts) -> Action {
        if let action = restoreCardAction(press, facts) { return action }
        // A sandboxed document's keys are its own: the web app's handler never
        // saw them either. ESC still un-borrows, through the card shim's relay.
        if facts.composing || facts.keys == .document { return .passThrough }
        if press.isCommandChord("k") { return .toggleSwitcher }
        if press.isCommandChord("w") { return .closeSelectedCard }
        if facts.switcherOpen { return .switcherKey }
        if press.isCommandChord("t") { return .newTerminal }
        let plain = !press.command && !press.option && !press.control
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
        if press.isRepeat { return facts.offer != .none || facts.afterRun ? .ignoreRepeat : nil }
        switch facts.offer {
        case .resumeArmed: return .runResume
        case .reopen: return .reopenDead
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
    private static func restoreCardAction(_ press: KeyPress, _ facts: Facts) -> Action? {
        guard facts.restoreCard || facts.afterRestoreCard, !press.isCommandChord("q") else { return nil }
        if press.isRepeat { return .ignoreRepeat }
        return facts.restoreCard ? .closeRestoreCard : nil
    }

    /// The latch after `press` was decided as `action`: set by closing the
    /// restore card, kept by a repeat, cleared by any other key.
    public static func afterRestoreCard(was: Bool, press: KeyPress, action: Action) -> Bool {
        latch(was: was, press: press, setBy: action == .closeRestoreCard)
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
