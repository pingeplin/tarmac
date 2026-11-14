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
        /// 2611.0011: the focused terminal is prime and its resume offer is
        /// armed.
        public var resumeArmed: Bool
        /// The focused terminal is dead and offers to reopen.
        public var reopenOffered: Bool
        /// The focused terminal shows a resume offer, armed or not, or a
        /// reopen offer.
        public var offerShown: Bool
        /// The focused terminal ran its command by `.runResume`, and no key
        /// that is not a repeat has come since (`afterRun(was:press:action:)`).
        public var afterRun: Bool

        public init(
            composing: Bool = false, switcherOpen: Bool = false, keys: Keys = .terminal, editingText: Bool = false,
            hasFlyTarget: Bool = false, esc: EscLadder.Facts = EscLadder.Facts(), resumeArmed: Bool = false,
            reopenOffered: Bool = false, offerShown: Bool = false, afterRun: Bool = false
        ) {
            self.composing = composing
            self.switcherOpen = switcherOpen
            self.keys = keys
            self.editingText = editingText
            self.hasFlyTarget = hasFlyTarget
            self.esc = esc
            self.resumeArmed = resumeArmed
            self.reopenOffered = reopenOffered
            self.offerShown = offerShown
            self.afterRun = afterRun
        }
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
    }

    public static func decide(_ press: KeyPress, _ facts: Facts) -> Action {
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
        if press.isRepeat { return facts.offerShown || facts.afterRun ? .ignoreRepeat : nil }
        if facts.resumeArmed { return .runResume }
        if facts.reopenOffered { return .reopenDead }
        return nil
    }

    /// The focused terminal's latch after `press` was decided as `action`:
    /// set by `.runResume`, kept by a repeat, cleared by any other key.
    public static func afterRun(was: Bool, press: KeyPress, action: Action) -> Bool {
        if action == .runResume { return true }
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
