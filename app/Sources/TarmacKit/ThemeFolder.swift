import Foundation

/// The one file operation of the themes (spec 2610.0009): the files of the
/// user's folder, with their bytes. It writes and makes nothing. The read is
/// `FileBytes`': a named pipe is refused and never waited on, and no more is
/// held than a theme file can be.
public enum ThemeFolder {
    public static func files(at path: String) -> [ThemeLibrary.File] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter(ThemeLibrary.reads).compactMap { name in
            contents(of: (path as NSString).appendingPathComponent(name)).map {
                ThemeLibrary.File(name: name, contents: $0)
            }
        }
    }

    /// `nil` for what is not a file: a folder, a pipe, a socket. A link is
    /// followed, and one to nothing cannot be read.
    private static func contents(of path: String) -> Result<Data, ThemeFile.Refusal>? {
        switch FileBytes.read(path: path, limit: ThemeFile.sizeLimit) {
        case .success(let data): .success(data)
        case .failure(is FileBytes.NotAFile): nil
        case .failure(let error as FileBytes.ReadError) where error.code == EISDIR: nil
        case .failure(is FileBytes.TooLarge): .failure(.tooLarge)
        case .failure: .failure(.unreadable)
        }
    }
}
