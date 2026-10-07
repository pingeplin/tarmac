import Foundation

/// The one file operation of the themes (spec 2610.0009): the files of the
/// user's folder, with their bytes. It writes and makes nothing. The read is
/// `FileBytes`': a named pipe is refused and never read or waited on, and a
/// file over the limit is refused, also when it grows while it is read.
public enum ThemeFolder {
    public static func files(at path: String) -> [ThemeLibrary.File] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter(ThemeLibrary.reads).compactMap { name in
            contents(of: (path as NSString).appendingPathComponent(name)).map {
                ThemeLibrary.File(name: name, contents: $0)
            }
        }
    }

    /// `nil` for what is not a file: a folder, a pipe, a socket, a device. A
    /// link is followed, and one to nothing cannot be read.
    private static func contents(of path: String) -> Result<Data, ThemeFile.Refusal>? {
        switch FileBytes.read(path: path, limit: ThemeFile.sizeLimit) {
        case .success(let data): .success(data)
        case .failure(is FileBytes.TooLarge): .failure(.tooLarge)
        case .failure: isFile(path) ? .failure(.unreadable) : nil
        }
    }

    /// Whether what failed to be read is a file, or a path that leads
    /// nowhere. The reader's own error does not say: a socket and a folder
    /// with no permission fail at the open, as a file with none does.
    private static func isFile(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) != 0 || status.st_mode & S_IFMT == S_IFREG
    }
}
