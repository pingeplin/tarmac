import CoreGraphics
import Foundation

/// Desk grid templates per docs/m1/crib-desk-tiles.md §1: 12px padding, 10px
/// gap, column/row fractions by tile count, and the n=3 row-span on slot 0.
/// Counts above 4 keep the 4-template columns and flow extra 1fr rows (the
/// prototype's untemplated degenerate state — reachable only via restore).
public enum DeskLayout {
    public static let padding: CGFloat = 12
    public static let gap: CGFloat = 10

    public static func frames(count: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let content = bounds.insetBy(dx: padding, dy: padding)
        if count == 1 { return [content] }

        let colFractions: [CGFloat] = count <= 3 ? [1.35, 1] : [1.25, 1]
        let rowFractions: [CGFloat]
        switch count {
        case 2: rowFractions = [1]
        case 3: rowFractions = [1, 1]
        default: rowFractions = [1.3] + Array(repeating: 1, count: (count + 1) / 2 - 1)
        }
        let colWidths = split(content.width, fractions: colFractions)
        let rowHeights = split(content.height, fractions: rowFractions)

        var colX: [CGFloat] = [content.minX]
        for w in colWidths.dropLast() { colX.append(colX.last! + w + gap) }
        var rowY: [CGFloat] = [content.minY]
        for h in rowHeights.dropLast() { rowY.append(rowY.last! + h + gap) }

        if count == 2 {
            return [
                CGRect(x: colX[0], y: rowY[0], width: colWidths[0], height: content.height),
                CGRect(x: colX[1], y: rowY[0], width: colWidths[1], height: content.height),
            ]
        }
        if count == 3 {
            return [
                CGRect(x: colX[0], y: rowY[0], width: colWidths[0], height: content.height),
                CGRect(x: colX[1], y: rowY[0], width: colWidths[1], height: rowHeights[0]),
                CGRect(x: colX[1], y: rowY[1], width: colWidths[1], height: rowHeights[1]),
            ]
        }
        return (0..<count).map { i in
            CGRect(x: colX[i % 2], y: rowY[i / 2], width: colWidths[i % 2], height: rowHeights[i / 2])
        }
    }

    private static func split(_ total: CGFloat, fractions: [CGFloat]) -> [CGFloat] {
        let avail = max(0, total - gap * CGFloat(fractions.count - 1))
        let sum = fractions.reduce(0, +)
        return fractions.map { avail * $0 / sum }
    }
}
