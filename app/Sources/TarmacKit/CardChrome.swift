/// Pure rule for a card's resting visual chrome — its border role and whether
/// the resize handles show. Collapses `focused`/`selected` into one "active
/// card" state (the teal ring + handles, always together) and keeps `prime`
/// (the keyboard target) out of the border entirely: prime is signalled by
/// header tint + shadow in the AppKit layer, never by a border here. Kept in
/// TarmacKit so the priority and the "ring ⟺ handles" invariant are unit-tested
/// away from AppKit (mirrors `EscFocusAction` / `FocusedClose`).
public enum CardChrome {
    /// Visual-state inputs for one card.
    public struct State: Equatable {
        public var dead: Bool
        public var detached: Bool
        public var fresh: Bool
        /// The keyboard target — intentionally NOT a border input.
        public var prime: Bool
        public var focused: Bool
        public var selected: Bool

        public init(
            dead: Bool = false,
            detached: Bool = false,
            fresh: Bool = false,
            prime: Bool = false,
            focused: Bool = false,
            selected: Bool = false
        ) {
            self.dead = dead
            self.detached = detached
            self.fresh = fresh
            self.prime = prime
            self.focused = focused
            self.selected = selected
        }
    }

    /// The resting border role; `CardView` maps each case to a `Theme` colour.
    public enum BorderRole: Equatable {
        /// Dead or detached — muted line.
        case muted
        /// The agent-opened "fresh" halo.
        case agent
        /// The unified active ring (teal) — an active card that is not dead/detached.
        case focus
        /// Nothing notable — the plain line.
        case plain
    }

    /// True when the card is the user's active target — a single click
    /// (`focused`) or an explicit header/handle grab (`selected`). NOT
    /// suppressed by `dead`/`detached`: a dead card stays resizable via a
    /// header grab, so its handles can still show even though its border is muted.
    public static func showsHandles(_ s: State) -> Bool {
        s.focused || s.selected
    }

    /// The resting border role, highest priority first:
    ///   dead || detached    -> .muted   (handles may still show — resize)
    ///   active (focus/sel.)  -> .focus   (the unified ring)
    ///   fresh                -> .agent
    ///   else                 -> .plain
    /// `prime` never appears — the keyboard target is signalled outside the border.
    public static func borderRole(_ s: State) -> BorderRole {
        if s.dead || s.detached { return .muted }
        if showsHandles(s) { return .focus }
        if s.fresh { return .agent }
        return .plain
    }
}
