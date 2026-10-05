/// The sizes a font role can be set in (spec 2610.0006): a range in half
/// steps, and the size with nothing saved.
///
/// There are two rules for a number, on purpose. The file holds what the app
/// wrote, so a number it could not have written is not used (`accepts`). A
/// typed number is what the user meant, so it goes to the nearest size the
/// role has (`nearest`).
public struct FontSizeRule: Equatable, Sendable {
    public static let step = 0.5

    public let range: ClosedRange<Double>
    public let standard: Double

    public func accepts(_ size: Double) -> Bool {
        range.contains(size) && (size / Self.step).rounded() == size / Self.step
    }

    public func inEffect(saved: Double?) -> Double {
        saved.flatMap { accepts($0) ? $0 : nil } ?? standard
    }

    /// The size to save when the user asks for `size`, or nil when that is
    /// no change: it is the size already in effect, whatever the file holds.
    /// So a number the reader refused stays in the file until a real choice.
    public func choice(_ size: Double, saved: Double?) -> Double? {
        accepts(size) && size != inEffect(saved: saved) ? size : nil
    }

    /// A tie between two sizes goes to the larger: 13.25 is 13.5.
    public func nearest(to size: Double) -> Double {
        min(max((size / Self.step).rounded() * Self.step, range.lowerBound), range.upperBound)
    }

    /// The size a typed text asks for, or nil for text that is not a finite
    /// number. The decimal mark is `.` in every locale.
    public func typed(_ text: String) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
        return nearest(to: number)
    }

    /// `16`, `13.5`: never `16.0`.
    public static func text(_ size: Double) -> String { size.javaScriptString }

    public static let terminal = FontSizeRule(range: 8...32, standard: 16)
    public static let document = FontSizeRule(range: 10...24, standard: 14)
}

extension FontRole {
    /// Interface has none: its chrome is set at many sizes, not one.
    public var sizeRule: FontSizeRule? {
        switch self {
        case .terminal: .terminal
        case .interface: nil
        case .document: .document
        }
    }

    public var sizePrefsKey: String { prefsKey + "_size" }
}
