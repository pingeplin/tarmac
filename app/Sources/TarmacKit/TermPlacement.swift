import CoreGraphics

/// Where a terminal card goes when nothing has placed it yet.
public enum TermPlacement {
    /// The cascade step of geometry-less restored terminals.
    public static let cascadeDX: CGFloat = 43
    public static let cascadeDY: CGFloat = 40

    /// A ⌘T terminal: the first free ring slot around the prime terminal (the
    /// boot frame when nothing is prime), the same rule a fresh doc follows.
    /// Always the boot size — the prime card's own size is not inherited.
    public static func newTerminalFrame(prime: CGRect?, existing: [CGRect]) -> CGRect {
        Placement.firstFreeSlot(
            owner: prime ?? Placement.termFrame, existing: existing, size: Placement.termFrame.size
        )
    }

    /// The frame of the `index`-th restored terminal tile that carries no
    /// geometry: the boot frame, one cascade step per tile before it.
    public static func restoredFrame(index: Int) -> CGRect {
        Placement.termFrame.offsetBy(
            dx: CGFloat(index) * cascadeDX, dy: CGFloat(index) * cascadeDY
        )
    }
}
