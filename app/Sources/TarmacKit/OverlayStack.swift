/// The overlays stacked over the board, and which covers which. Cases are in
/// the order `desktop/src/App.tsx` mounts them, which is what breaks a tie.
///
/// The status bar is not here: it sits below the board area, not over it. Nor
/// are the pills that could not clear a card, which go inside the board, under
/// its cards.
public enum OverlayStack: CaseIterable, Sendable {
    case zoomControl, minimap, hints, toasts, switcher, cycleHUD

    /// The overlay's `z-index` in `desktop/src/theme/chrome.css`. The switcher's
    /// veil (79) and panel (80) are one view here.
    public var zIndex: Int {
        switch self {
        case .zoomControl, .minimap: return 50
        case .hints: return 40
        case .toasts: return 70
        case .switcher: return 80
        case .cycleHUD: return 90
        }
    }

    public static var backToFront: [OverlayStack] {
        allCases.enumerated()
            .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
            .map(\.element)
    }
}
