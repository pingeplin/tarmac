import Foundation

/// The markdown a doc card renders: its file as UTF-8 text, or a note saying
/// why it could not be read.
public enum DocSource {
    public static func unreadable(path: String, reason: String) -> String {
        "*could not read \(path)*\n\n```\n\(reason)\n```"
    }

    public static func markdown(path: String, contents: Result<Data, any Error>) -> String {
        switch contents {
        case .failure(let error):
            return unreadable(path: path, reason: error.localizedDescription)
        case .success(let data):
            return String(data: data, encoding: .utf8)
                ?? unreadable(path: path, reason: "stream did not contain valid UTF-8")
        }
    }
}
