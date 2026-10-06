import AppKit
import TarmacKit

/// What the overlays draw a card's signal with, and their drop shadows — the
/// values `desktop/src/theme/tokens.css` lists as alpha-derived chrome colours
/// and shadows for non-zooming chrome. The minimap and the edge pills both
/// read live and bell from here, so the two cannot drift apart.
@MainActor
enum OverlayPalette {
    static var minimapBackground: NSColor { Theme.bg0.withAlphaComponent(0.92) }

    /// A card's rect in the minimap.
    static func minimapFill(_ signal: CardSignal) -> NSColor {
        switch signal {
        case .live: return Theme.agent.withAlphaComponent(0.8)
        case .bell: return Theme.amber.withAlphaComponent(0.85)
        case .none: return Theme.bg3
        }
    }

    static func hintBorder(_ signal: OffscreenHintLayout.Signal) -> NSColor {
        switch signal {
        case .live: return Theme.agent.withAlphaComponent(0.4)
        case .bell: return Theme.amber.withAlphaComponent(0.5)
        }
    }

    static func hintArrow(_ signal: OffscreenHintLayout.Signal) -> NSColor {
        switch signal {
        case .live: return Theme.faint
        case .bell: return Theme.amber
        }
    }

    static func hintLabel(_ signal: OffscreenHintLayout.Signal) -> NSColor {
        switch signal {
        case .live: return Theme.muted
        case .bell: return Theme.text
        }
    }

    static var hintShadow: NSShadow { dropShadow(y: 8, blur: 22) }
    static var toastShadow: NSShadow { dropShadow(y: 10, blur: 14) }

    /// `0 <y>px <blur>px rgba(0,0,0,0.5)`. A stylesheet's blur is twice the
    /// radius AppKit takes, which is how the card shadows are ported too.
    static func dropShadow(y: CGFloat, blur: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -y)
        shadow.shadowBlurRadius = blur / 2
        return shadow
    }
}

extension CardSignal {
    /// The signal as the edge pills and the ⏎ flight know it: nil for none.
    var wayfinding: OffscreenHintLayout.Signal? {
        switch self {
        case .live: return .live
        case .bell: return .bell
        case .none: return nil
        }
    }
}
