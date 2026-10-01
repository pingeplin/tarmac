import CoreGraphics

/// Where a QA-driver press may land on a target (spec 2609.0015, issue #166).
///
/// A native press is hit-tested, so it reaches its target only at a point
/// nothing else covers: the middle of the board is usually under a card, and
/// the middle of a card may be under another. These are the points the app
/// tries, in order — the middle first, then the rect cell by cell — taking the
/// first its hit test resolves to the target.
public enum DevTargetPoints {
    public static let gridSide = 6

    public static func candidates(in rect: CGRect) -> [CGPoint] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let cell = CGSize(width: rect.width / CGFloat(gridSide), height: rect.height / CGFloat(gridSide))
        var points = [CGPoint(x: rect.midX, y: rect.midY)]
        for row in 0..<gridSide {
            for col in 0..<gridSide {
                points.append(CGPoint(
                    x: rect.minX + (CGFloat(col) + 0.5) * cell.width,
                    y: rect.minY + (CGFloat(row) + 0.5) * cell.height
                ))
            }
        }
        return points
    }
}
