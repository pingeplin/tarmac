/// Pure rule for a card's border. The lift of a move or resize and the borrow
/// of an HTML card each override the resting border. The resting border keeps
/// both `prime` (the keyboard target) and `fresh` (an agent-opened, unread
/// card) out entirely: prime is signalled by header tint + shadow, fresh by its
/// halo + `✚ now` meta in the AppKit layer, never by a border here. So that
/// border collapses to one axis — dead/selected/plain — with `prime` and
/// `fresh` both inert. Kept in TarmacKit so the priority is unit-tested away
/// from AppKit (mirrors `EscFocusAction` / `FocusedClose`).
public enum CardChrome {
    /// Visual-state inputs for one card.
    public struct State: Equatable {
        public var dead: Bool
        /// Agent-opened and unread — signalled by halo + `✚ now` meta in the
        /// AppKit layer, intentionally NOT a border input.
        public var fresh: Bool
        /// The keyboard target — intentionally NOT a border input.
        public var prime: Bool
        public var selected: Bool

        public init(
            dead: Bool = false,
            fresh: Bool = false,
            prime: Bool = false,
            selected: Bool = false
        ) {
            self.dead = dead
            self.fresh = fresh
            self.prime = prime
            self.selected = selected
        }
    }

    /// The resting border role; `CardView` maps each case to a `Theme` colour.
    public enum BorderRole: Equatable {
        /// Dead — muted line.
        case muted
        /// The teal ring — the selected card, unless it is dead.
        case focus
        /// Nothing notable — the plain line.
        case plain
    }

    /// The resting border role, highest priority first:
    ///   dead      -> .muted
    ///   selected  -> .focus   (the ring)
    ///   else      -> .plain
    /// Neither `prime` nor `fresh` appears — both are signalled outside the
    /// border (prime by header tint + shadow, fresh by its halo + `✚ now` meta).
    public static func borderRole(_ s: State) -> BorderRole {
        if s.dead { return .muted }
        return s.selected ? .focus : .plain
    }

    /// The border a card draws.
    public enum Border: Equatable {
        /// A move or a resize holds the card.
        case lift
        /// The borrowed HTML card, which holds the keyboard.
        case borrowed
        case resting(BorderRole)
    }

    /// The whole border rule: lift, then borrowed, then the resting role.
    public static func border(_ s: State, lifted: Bool, borrowed: Bool) -> Border {
        if lifted { return .lift }
        return borrowed ? .borrowed : .resting(borderRole(s))
    }
}
