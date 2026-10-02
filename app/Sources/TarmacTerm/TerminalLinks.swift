import Foundation
import GhosttyVt

struct RowLink: Equatable {
    /// Inclusive column range the URL occupies on its row.
    var cols: ClosedRange<Int>
    var url: String
}

/// Plain-text URL detection over one rendered row.
enum TerminalLinks {
    /// xterm.js's web-links pattern, so the native card links exactly what the
    /// xterm card did: http(s) only, trailing punctuation left out.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(https?|HTTPS?)://[^\s"'!*(){}|\\^<>`]*[^\s"':,.!?{}|\\^~\[\]`()<>]"#
    )

    static func urls(in row: FrameRow) -> [RowLink] {
        var text = ""
        var columns: [Int] = []
        for (col, cell) in row.cells.enumerated() where cell.width != .spacer {
            let piece = cell.text.isEmpty ? " " : cell.text
            text += piece
            columns.append(contentsOf: repeatElement(col, count: piece.utf16.count))
        }
        let whole = NSRange(location: 0, length: columns.count)
        return pattern.matches(in: text, range: whole).map { match in
            let last = columns[match.range.upperBound - 1]
            let end = row.cells[last].width == .wide ? last + 1 : last
            return RowLink(cols: columns[match.range.location]...end, url: (text as NSString).substring(with: match.range))
        }
    }

    static func url(in row: FrameRow, atCol col: Int) -> String? {
        urls(in: row).first { $0.cols.contains(col) }?.url
    }
}

extension TerminalEngine {
    /// The OSC 8 hyperlink target of a viewport cell, if the program set one.
    func hyperlink(col: Int, row: Int) -> String? {
        guard var ref = gridRef(GHOSTTY_POINT_TAG_VIEWPORT, col: col, row: row) else { return nil }

        var buffer = [UInt8](repeating: 0, count: 512)
        var length = 0
        var result = ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length)
        if result == GHOSTTY_OUT_OF_SPACE {
            buffer = [UInt8](repeating: 0, count: length)
            result = ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length)
        }
        guard result == GHOSTTY_SUCCESS, length > 0 else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }
}
