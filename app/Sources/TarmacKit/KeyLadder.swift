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
    }

    public struct Facts: Equatable, Sendable {
        /// The focused terminal has an IME composition in flight.
        public var composing: Bool
        public var switcherOpen: Bool
        public var keys: Keys
        /// A signalling card is off screen, so Return has somewhere to fly.
        public var hasFlyTarget: Bool
        public var esc: EscLadder.Facts

        public init(
            composing: Bool = false, switcherOpen: Bool = false, keys: Keys = .terminal, hasFlyTarget: Bool = false,
            esc: EscLadder.Facts = EscLadder.Facts()
        ) {
            self.composing = composing
            self.switcherOpen = switcherOpen
            self.keys = keys
            self.hasFlyTarget = hasFlyTarget
            self.esc = esc
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
        /// ⌘C with a doc card selected: copy that card's text selection. A doc's
        /// web view never takes keyboard focus, so the menu's Copy, which
        /// goes to the first responder, cannot reach it.
        case copyDocSelection
        /// ⌥Tab.
        case cycleTerminals
        /// ⌘T.
        case newTerminal
        /// Return: remember the viewport and fly to the offscreen signal.
        case flyToSignal
        case esc(EscLadder.Rung)
    }

    public static func decide(_ press: KeyPress, _ facts: Facts) -> Action {
        // A sandboxed document's keys are its own: the web app's handler never
        // saw them either. ESC still un-borrows, through the card shim's relay.
        if facts.composing || facts.keys == .document { return .passThrough }
        if press.isCommandChord("k") { return .toggleSwitcher }
        if press.isCommandChord("w") { return .closeSelectedCard }
        if facts.switcherOpen { return .switcherKey }
        if press.isCommandChord("c"), !press.shift, facts.esc.selectedIsDoc { return .copyDocSelection }
        if press.named == .tab, press.option, !press.command, !press.control, !press.shift {
            return .cycleTerminals
        }
        if press.isCommandChord("t") { return .newTerminal }
        let plain = !press.command && !press.option && !press.control
        if press.named == .enter, plain, facts.keys == .host, facts.hasFlyTarget { return .flyToSignal }
        if press.named == .escape, let rung = EscLadder.rung(facts.esc) { return .esc(rung) }
        return .passThrough
    }
}
