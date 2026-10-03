import CoreGraphics

/// The pixel density a card's content is rasterised at. The board zooms a
/// card by scaling what it drew, so above 100 % the content is drawn denser by
/// the zoom, up to a cap that bounds memory; at or below 100 % the display's
/// own density is kept and the card is scaled down.
///
/// The density follows the zoom exactly; the half-step snapping of the web
/// app's `rasterScale.ts` is not ported.
public enum CardRaster {
    public static let maxZoom: CGFloat = 3

    /// The scale for the card's own layers, on a display of `backing` density.
    public static func layerScale(backing: CGFloat, zoom: CGFloat) -> CGFloat {
        backing * min(max(zoom, 1), maxZoom)
    }
}
