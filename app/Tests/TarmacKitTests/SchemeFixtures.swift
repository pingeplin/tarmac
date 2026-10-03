import Foundation
@testable import TarmacKit

enum SchemeFixtures {
    /// Every byte outside ASCII alphanumerics, as the Rust tests' `NON_ALPHANUMERIC`
    /// does. `.alphanumerics` would let CJK letters through raw.
    static func encoded(_ s: String) -> String {
        s.utf8.map { byte in
            let alnum = (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            return alnum ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    static func docURI(_ path: String, v: Int = 1) -> String {
        "tarmac-card://doc/\(encoded(path))?v=\(v)"
    }

    static func imgURI(_ path: String, v: Int = 1) -> String {
        "tarmac-card://img/\(encoded(path))?v=\(v)"
    }

    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    struct NoSuchFile: Error {}

    /// A filesystem of fixed contents that records every open, so a test can say
    /// a file was never touched. `links` are its symlinks, each to the file it
    /// leads to.
    final class Disk {
        let files: [String: Data]
        let links: [String: String]
        private(set) var opened: [String] = []

        init(_ files: [String: Data] = [:], links: [String: String] = [:]) {
            self.files = files
            self.links = links
        }

        func read(_ path: String) -> Result<Data, any Error> {
            opened.append(path)
            return files[links[path] ?? path].map { .success($0) } ?? .failure(NoSuchFile())
        }

        func resolve(_ path: String) -> Result<String, any Error> {
            let file = links[path] ?? path
            return files[file] == nil ? .failure(NoSuchFile()) : .success(file)
        }
    }
}
