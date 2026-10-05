import Foundation
import GhosttyVt

/// The cells a link covers on one row.
struct LinkSpan: Equatable {
    var row: Int
    /// Inclusive column range.
    var cols: ClosedRange<Int>
}

struct TerminalLink: Equatable {
    var url: String
    /// One span per row the link runs over, top first.
    var spans: [LinkSpan]
}

private extension FrameCell {
    var isBlank: Bool { width != .spacer && text.allSatisfy(\.isWhitespace) }
}

/// One line of text and the cells each UTF-16 unit of it came from.
private struct TextLine {
    private(set) var text = ""
    private(set) var cells: [LinkSpan] = []
    /// The columns taken by the word the line ends in: none when it ends blank.
    private(set) var lastWordColumns = 0

    mutating func append(_ row: FrameRow, at index: Int, from first: Int = 0) {
        for (col, cell) in row.cells.enumerated().dropFirst(first) where cell.width != .spacer {
            let piece = cell.text.isEmpty ? " " : cell.text
            text += piece
            let span = LinkSpan(row: index, cols: col...(cell.width == .wide ? col + 1 : col))
            cells.append(contentsOf: repeatElement(span, count: piece.utf16.count))
            lastWordColumns = cell.isBlank ? 0 : lastWordColumns + span.cols.count
        }
    }
}

/// Plain-text URL detection over rendered rows.
enum TerminalLinks {
    private static let scheme = "(https?|HTTPS?)://"
    private static let startsWithScheme = try! NSRegularExpression(pattern: "^" + scheme)
    /// xterm.js's web-links pattern, so the native card links exactly what the
    /// xterm card did: http(s) only, trailing punctuation left out.
    private static let pattern = try! NSRegularExpression(
        pattern: scheme + #"[^\s"'!*(){}|\\^<>`]*[^\s"':,.!?{}|\\^~\[\]`()<>]"#
    )

    private static func urls(in line: TextLine) -> [TerminalLink] {
        let whole = NSRange(location: 0, length: line.cells.count)
        return pattern.matches(in: line.text, range: whole).map { match in
            var spans: [LinkSpan] = []
            for cell in line.cells[match.range.location..<match.range.upperBound] {
                if let last = spans.indices.last, spans[last].row == cell.row {
                    spans[last].cols = spans[last].cols.lowerBound...cell.cols.upperBound
                } else {
                    spans.append(cell)
                }
            }
            return TerminalLink(url: (line.text as NSString).substring(with: match.range), spans: spans)
        }
    }

    /// The URL at a cell of `rows`. `wraps` says whether the terminal wrapped
    /// a row's line onto the next row.
    static func link(in rows: [FrameRow], atCol col: Int, row: Int, wraps: (Int) -> Bool) -> TerminalLink? {
        // A line reaches this row from above only through rows that wrap or
        // are filled to the edge.
        var start = row
        while start > 0, wraps(start - 1) || isFilled(rows[start - 1]) { start -= 1 }
        while true {
            let (line, last) = line(in: rows, from: start, wraps: wraps)
            guard last < row else {
                return urls(in: line).first { link in
                    link.spans.contains { $0.row == row && $0.cols.contains(col) }
                }
            }
            start = last + 1
        }
    }

    /// The line of text that starts on row `start`, and the row it ends on.
    private static func line(in rows: [FrameRow], from start: Int, wraps: (Int) -> Bool) -> (TextLine, last: Int) {
        var line = TextLine()
        line.append(rows[start], at: start)
        var last = start
        while last + 1 < rows.count {
            let next = rows[last + 1]
            if wraps(last) {
                line.append(next, at: last + 1)
            } else if let indent = brokenWordContinuation(of: line, on: next) {
                line.append(next, at: last + 1, from: indent)
            } else {
                break
            }
            last += 1
        }
        return (line, last)
    }

    /// The column of `next` where a word goes on that the program broke over
    /// rows itself, as Claude Code does a long URL, rather than let the
    /// terminal wrap. Nothing marks such a break, so it is read off the
    /// layout: the row ends in a word at its last column, and that word with
    /// the first one below is too long for a row — a word that fits is moved
    /// to the next row whole, never split. Two words that happen to lie that
    /// way look the same, so a URL that ends at the edge with less room before
    /// it than the next row's first word is long takes that word; a first
    /// word that starts a URL of its own is never taken.
    private static func brokenWordContinuation(of line: TextLine, on next: FrameRow) -> Int? {
        guard let indent = next.cells.firstIndex(where: { !$0.isBlank }) else { return nil }
        let head = next.cells[indent...].prefix { !$0.isBlank }
        let word = head.map(\.text).joined()
        guard startsWithScheme.firstMatch(in: word, range: NSRange(location: 0, length: word.utf16.count)) == nil,
              line.lastWordColumns + head.count > next.cells.count - indent else { return nil }
        return indent
    }

    private static func isFilled(_ row: FrameRow) -> Bool {
        row.cells.last.map { !$0.isBlank } ?? false
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

    /// Whether the terminal wrapped a viewport row's line onto the next row.
    func isSoftWrapped(row: Int) -> Bool {
        guard var ref = gridRef(GHOSTTY_POINT_TAG_VIEWPORT, col: 0, row: row) else { return false }
        var line: GhosttyRow = 0
        var wrapped = false
        guard ghostty_grid_ref_row(&ref, &line) == GHOSTTY_SUCCESS,
              ghostty_row_get(line, GHOSTTY_ROW_DATA_WRAP, &wrapped) == GHOSTTY_SUCCESS else { return false }
        return wrapped
    }
}
