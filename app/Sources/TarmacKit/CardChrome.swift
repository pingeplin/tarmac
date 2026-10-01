/// Pure rule for a card's resting visual chrome — its border role and whether
/// it reads as the active card. Collapses `focused`/`selected` into one "active
/// card" state (the teal ring) and keeps both
/// `prime` (the keyboard target) and `fresh` (an agent-opened, unread card) out
/// of the border entirely: prime is signalled by header tint + shadow, fresh by
/// its halo + `✚ now` meta in the AppKit layer, never by a border here. So the
/// border collapses to one axis — dead/active/plain — with `prime` and `fresh`
/// both inert. Resize hit-areas are live on every card; only the ring is
/// focus-gated, so an idle card never shows it. Kept in TarmacKit so the
/// priority is unit-tested away from AppKit (mirrors `EscFocusAction` /
/// `FocusedClose`).
public enum CardChrome {
    /// Visual-state inputs for one card.
    public struct State: Equatable {
        public var dead: Bool
        /// Agent-opened and unread — signalled by halo + `✚ now` meta in the
        /// AppKit layer, intentionally NOT a border input.
        public var fresh: Bool
        /// The keyboard target — intentionally NOT a border input.
        public var prime: Bool
        public var focused: Bool
        public var selected: Bool

        public init(
            dead: Bool = false,
            fresh: Bool = false,
            prime: Bool = false,
            focused: Bool = false,
            selected: Bool = false
        ) {
            self.dead = dead
            self.fresh = fresh
            self.prime = prime
            self.focused = focused
            self.selected = selected
        }
    }

    /// The resting border role; `CardView` maps each case to a `Theme` colour.
    public enum BorderRole: Equatable {
        /// Dead — muted line.
        case muted
        /// The unified active ring (teal) — an active card that is not dead.
        case focus
        /// Nothing notable — the plain line.
        case plain
    }

    /// True when the card is the user's active target — a single click
    /// (`focused`) or an explicit header/handle grab (`selected`). Gates the
    /// ring only, never the resize hit-areas, and is NOT suppressed by `dead`.
    public static func showsHandles(_ s: State) -> Bool {
        s.focused || s.selected
    }

    /// The resting border role, highest priority first:
    ///   dead                 -> .muted   (handles may still show — resize)
    ///   active (focus/sel.)  -> .focus   (the unified ring)
    ///   else                 -> .plain
    /// Neither `prime` nor `fresh` appears — both are signalled outside the
    /// border (prime by header tint + shadow, fresh by its halo + `✚ now` meta).
    public static func borderRole(_ s: State) -> BorderRole {
        if s.dead { return .muted }
        if showsHandles(s) { return .focus }
        return .plain
    }
}
