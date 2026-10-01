/// A key that reads as held until a deadline, whatever the keyboard says: what
/// `tarmac dev press` arms on the ⌘Q guard's release poll (spec 2609.0018), so
/// a posted chord can be "held" with no finger on a key. `untilMs` is on the
/// clock the poll samples with.
public struct KeyHold: Equatable, Sendable {
    public var keyCode: UInt16
    public var untilMs: UInt64

    public init(keyCode: UInt16, untilMs: UInt64) {
        self.keyCode = keyCode
        self.untilMs = untilMs
    }

    public func holds(_ keyCode: UInt16, nowMs: UInt64) -> Bool {
        keyCode == self.keyCode && nowMs < untilMs
    }
}
