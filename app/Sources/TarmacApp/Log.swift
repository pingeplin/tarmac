import Foundation

/// The app's own output: one `tarmac: `-prefixed line on stderr.
enum Log {
    static func stderr(_ line: String) {
        FileHandle.standardError.write(Data("tarmac: \(line)\n".utf8))
    }
}
