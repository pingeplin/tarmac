import Foundation

/// Where a card's content is scrolled to, in any one unit of that content: a
/// terminal's rows, a web page's pixels. Only the ratios are ever drawn.
public struct ScrollMetrics: Equatable, Sendable {
    /// Of the first visible unit, from the start.
    public let offset: Double
    public let visible: Double
    public let total: Double

    /// Nil for numbers that describe no scroller. An offset outside its range
    /// is the nearest edge: a page reports one while it rubber-bands.
    public init?(offset: Double, visible: Double, total: Double) {
        guard offset.isFinite, visible.isFinite, total.isFinite, visible > 0, total >= visible else { return nil }
        self.offset = min(max(offset, 0), total - visible)
        self.visible = visible
        self.total = total
    }

    /// A web card's report, `{offset, visible, total}`, as a script message
    /// carries it.
    public init?(report: Any) {
        guard let fields = report as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            guard let raw = fields[key], case .number(let value)? = JSONValue(foundation: raw) else { return nil }
            return value
        }
        guard let offset = number("offset"), let visible = number("visible"), let total = number("total") else { return nil }
        self.init(offset: offset, visible: visible, total: total)
    }

    public var overflows: Bool { total > visible }
}
