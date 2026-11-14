import AppKit
import TarmacKit

/// What the overlays draw a card's signal with, and their drop shadows — the
/// values `desktop/src/theme/tokens.css` lists as alpha-derived chrome colours
/// and shadows for non-zooming chrome. The minimap and the edge pills both
/// read a card's signal colour from here, so the two cannot drift apart.
@MainActor
enum OverlayPalette {
    static var minimapBackground: NSColor { Theme.bg0.withAlphaComponent(0.92) }

    /// A card's rect in the minimap.
    static func minimapFill(_ signal: OffscreenHintLayout.Signal?) -> NSColor {
        switch signal {
        case .live: return Theme.agent.withAlphaComponent(0.8)
        case let signal?: return tone(signal).withAlphaComponent(0.85)
        case nil: return Theme.bg3
        }
    }

    static func hintBorder(_ signal: OffscreenHintLayout.Signal) -> NSColor {
        signal == .live ? Theme.agent.withAlphaComponent(0.4) : tone(signal).withAlphaComponent(0.5)
    }

    static func hintArrow(_ signal: OffscreenHintLayout.Signal) -> NSColor {
        signal == .live ? Theme.faint : tone(signal)
    }

    static func hintLabel(_ signal: OffscreenHintLayout.Signal) -> NSColor {
        signal == .live ? Theme.muted : Theme.text
    }

    /// A signal's colour: a blocked report and a bell want the user, a done
    /// report is good news, an exit is an error. The pills, the minimap and the
    /// report and inbox chips all read it here.
    static func tone(_ signal: OffscreenHintLayout.Signal) -> NSColor {
        switch signal {
        case .blocked, .bell: return Theme.amber
        case .done: return Theme.ok
        case .exit: return Theme.consoleError
        case .live: return Theme.agent
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
