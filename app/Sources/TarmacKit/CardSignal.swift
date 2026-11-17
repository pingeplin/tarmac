/// What a terminal card shows on the minimap, its edge pill and its inbox
/// tag (spec 2611.0013): one signal, and its rank.
public enum CardSignal: String, Equatable, Sendable {
    case blocked, bell, exit, done, live

    /// Blocked 4, bell 3, exit 2, done 1, live 0.
    public var rank: Int {
        switch self {
        case .blocked: 4
        case .bell: 3
        case .exit: 2
        case .done: 1
        case .live: 0
        }
    }

    /// A card's one signal, the highest it has. A read report makes none: the
    /// card falls through to its other facts.
    public static func of(report: TermReport?, bellLit: Bool, exitUnread: Bool, live: Bool) -> CardSignal? {
        let unread = report.flatMap { $0.read ? nil : $0.kind }
        if unread == .blocked { return .blocked }
        if bellLit { return .bell }
        if exitUnread { return .exit }
        if unread == .done { return .done }
        return live ? .live : nil
    }
}
