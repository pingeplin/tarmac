import Synchronization

/// Who owes the window a comeback (spec 2609.0016).
///
/// The red button hides the window instead of quitting, so something has to bring
/// it back. Both triggers can fire for one Dock click on an inactive app —
/// `applicationDidBecomeActive` and the reopen request — so the restore is handed
/// out once per close, not once per trigger. The quit guard's own hide never
/// calls `closeRequested`: a hidden-then-quitting window must stay hidden.
///
/// Owns its own synchronisation, so the window delegate and the two restore
/// triggers share one instance without any call site spelling a lock.
public final class HiddenByClose: Sendable {
    private let hidden = Atomic<Bool>(false)

    public init() {}

    public func closeRequested() {
        hidden.store(true, ordering: .sequentiallyConsistent)
    }

    /// True once after a close, then false until the next one.
    public func takeRestore() -> Bool {
        hidden.exchange(false, ordering: .sequentiallyConsistent)
    }
}
