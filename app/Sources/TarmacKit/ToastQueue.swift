/// The queue, expiry and overflow rules of the bottom-right transient
/// notification stack. Time is injected (`nowMs`) so expiry is deterministic;
/// slide/fade animation and truncation stay in the view layer.
public struct ToastQueue: Equatable, Sendable {
    public static let maxToasts = 3
    public static let ttlMs = 7000

    public struct Toast: Equatable, Sendable {
        public var id: String
        /// A leading mono glyph: "¶" for connection toasts, "›_" for shell toasts.
        public var icon: String
        public var title: String
        public var body: String?
        public var expiresAtMs: Int
    }

    /// Insertion order; the newest is LAST (rendered at the bottom of the stack).
    public private(set) var toasts: [Toast] = []

    public init() {}

    /// Appends a toast as the newest, expiring at `nowMs + ttlMs` (saturating at
    /// `Int.max`). Past `maxToasts` the OLDEST is evicted. Identical toasts are not
    /// coalesced.
    public mutating func add(
        id: String,
        icon: String,
        title: String,
        body: String? = nil,
        nowMs: Int
    ) {
        let (expiresAtMs, overflowed) = nowMs.addingReportingOverflow(Self.ttlMs)
        toasts.append(Toast(
            id: id, icon: icon, title: title, body: body,
            expiresAtMs: overflowed ? .max : expiresAtMs
        ))
        if toasts.count > Self.maxToasts { toasts.removeFirst(toasts.count - Self.maxToasts) }
    }

    /// Drops every toast whose TTL has elapsed (`expiresAtMs <= nowMs`).
    public mutating func pruneExpired(nowMs: Int) {
        toasts.removeAll { $0.expiresAtMs <= nowMs }
    }

    /// Clears the entire stack (the ESC ladder's toast rung).
    public mutating func clearAll() {
        toasts.removeAll()
    }
}
