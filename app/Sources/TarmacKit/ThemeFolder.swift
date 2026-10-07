import Foundation

/// The one file operation of the themes (spec 2610.0009): the files of the
/// user's folder, with their bytes. It writes and makes nothing, and it opens
/// nothing but a regular file: a named pipe would block the app.
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
    /// followed, and one to nothing cannot be read. No more than one byte
    /// over the limit is read, whatever size the file has by then.
    private static func contents(of path: String) -> Result<Data, ThemeFile.Refusal>? {
        var status = stat()
        guard stat(path, &status) == 0 else { return .failure(.unreadable) }
        guard status.st_mode & S_IFMT == S_IFREG else { return nil }
        guard let file = FileHandle(forReadingAtPath: path),
            let data = try? file.read(upToCount: ThemeFile.sizeLimit + 1)
        else { return .failure(.unreadable) }
        return data.count > ThemeFile.sizeLimit ? .failure(.tooLarge) : .success(data)
    }
}
