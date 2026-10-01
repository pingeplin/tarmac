import CoreGraphics

/// Where a terminal card goes when nothing has placed it yet.
public enum TermPlacement {
    /// A ⌘T terminal: one cascade step down-right of the prime terminal's
    /// origin (the boot origin when nothing is prime), stepped further while it
    /// would sit on an existing card's origin. Always the boot size — the prime
    /// card's own size is not inherited.
    public static func newTerminalFrame(primeOrigin: CGPoint?, existingOrigins: [CGPoint]) -> CGRect {
        let origin = BoardWayfinding.cascadeOrigin(
            base: primeOrigin ?? Placement.termFrame.origin,
            existing: existingOrigins,
            dx: Placement.cascadeDX,
            dy: Placement.cascadeDY
        )
        return CGRect(origin: origin, size: Placement.termFrame.size)
    }

    /// One above the board's top card; the top is never taken to be below zero.
    public static func newTerminalZ(existing: [Int]) -> Int {
        existing.reduce(0, max) + 1
    }

    /// The frame of the `index`-th restored terminal tile that carries no
    /// geometry: the boot frame, one cascade step per tile before it.
    public static func restoredFrame(index: Int) -> CGRect {
        Placement.termFrame.offsetBy(
            dx: CGFloat(index) * Placement.cascadeDX, dy: CGFloat(index) * Placement.cascadeDY
        )
    }
}
