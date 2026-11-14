/// The overlays stacked over the board, and which covers which. Cases are in
/// the order `desktop/src/App.tsx` mounts them, which is what breaks a tie.
///
/// The status bar is not here: it sits below the board area, not over it.
public enum OverlayStack: CaseIterable, Sendable {
    case zoomControl, minimap, hints, toasts, switcher, restoreCard, inbox

    /// The overlay's `z-index` in `desktop/src/theme/chrome.css`. The switcher's
    /// veil (79) and panel (80) are one view here. The restore card (#358) has
    /// no stylesheet: it takes the first key, so it is drawn over everything.
    /// The inbox panel (2611.0013) has none either: over the pills, the zoom
    /// control and the minimap, under the toasts and the switcher.
    public var zIndex: Int {
        switch self {
        case .zoomControl, .minimap: return 50
        case .hints: return 40
        case .toasts: return 70
        case .switcher: return 80
        case .restoreCard: return 90
        case .inbox: return 60
        }
    }

    public static var backToFront: [OverlayStack] {
        allCases.enumerated()
            .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
            .map(\.element)
    }
}
