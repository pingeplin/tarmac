/// Spec 2609.0017 (#172): whether a first-visit restore after a version-mismatch
/// daemon restart gets a toast. Loss is proven by a persisted term id that came
/// back not live, never by a bare cold spawn — every fresh ⌘N board yields one of
/// those with nothing lost. The once-per-restart latch and the toast itself stay
/// in the app.
public struct RestartNotice: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// The daemon version pair of a replaced daemon. A nil version reads as
    /// "unknown": the restart fired on `!=`, so the arrow claims no direction.
    public struct Replacement: Equatable, Sendable {
        public var from: String?
        public var to: String?

        public init(from: String?, to: String?) {
            self.from = from
            self.to = to
        }
    }

    /// Non-nil iff a daemon was replaced, the restart wasn't already notified, and
    /// at least one tile carries a persisted id absent from `liveTerms`. A nil tile
    /// id (a board that never spawned a terminal) is never counted as lost.
    public static func make(
        replaced: Replacement?,
        tileTermIDs: [String?],
        liveTerms: Set<String>,
        alreadyNotified: Bool
    ) -> RestartNotice? {
        guard let replaced, !alreadyNotified else { return nil }
        let lost = tileTermIDs.compactMap { $0 }.filter { !liveTerms.contains($0) }.count
        guard lost > 0 else { return nil }
        return RestartNotice(
            title: "tarmacd restarted: \(replaced.from ?? "unknown") → \(replaced.to ?? "unknown")",
            body: lost == 1
                ? "1 terminal on this board was restarted"
                : "\(lost) terminals on this board were restarted"
        )
    }
}
