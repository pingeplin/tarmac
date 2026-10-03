import CoreGraphics

/// Tells a change of the display's density from the other things AppKit
/// reports as "backing properties changed". A view inside a scaled ancestor
/// gets that callback whenever the ancestor's scale moves — on every step of a
/// board zoom — and only the window's own scale changing is a new display.
public struct BackingScaleWatch: Equatable, Sendable {
    private var last: CGFloat?

    public init() {}

    /// Whether `scale`, the window's backing scale or nil out of a window, is
    /// a density not seen last time.
    public mutating func changed(to scale: CGFloat?) -> Bool {
        guard let scale, scale != last else { return false }
        last = scale
        return true
    }
}
