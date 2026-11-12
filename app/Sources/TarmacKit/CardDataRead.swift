import Foundation

/// One read of an HTML card's data file (specs 2611.0002, 2611.0005): both
/// files are resolved, the resolved data file must be under the resolved HTML
/// file's directory with no hidden name below it, and that resolved file is
/// the one read. `resolve` and `read` are the
/// caller's, as `ImageProtocol.respond(path:file:read:)` takes them; the view
/// passes `FileBytes.resolved` and `FileBytes.read` and runs this off the main
/// thread.
public enum CardDataRead {
    public enum Outcome: Equatable, Sendable {
        /// Strict JSON, as text.
        case text(String)
        /// Why nothing is delivered; the console line names the path.
        case refused(String)
    }

    static let leadsOutside = "leads outside this card's directory"
    static let leadsToHidden = "leads to a hidden file or directory"
    static let notUTF8 = "not UTF-8"
    static let notJSON = "not valid JSON"

    public static func read(
        file: String, html: String,
        resolve: (String) -> Result<String, any Error>, read: (String) -> Result<Data, any Error>
    ) -> Outcome {
        let resolved: String
        switch resolve(file) {
        case .failure(let error): return .refused(error.localizedDescription)
        case .success(let path): resolved = path
        }
        let card: String
        switch resolve(html) {
        case .failure(let error): return .refused("the card's file: \(error.localizedDescription)")
        case .success(let path): card = path
        }
        guard let below = CardDataPath.below(resolved, html: card) else { return .refused(leadsOutside) }
        guard !CardDataPath.isHidden(below) else { return .refused(leadsToHidden) }
        switch read(resolved) {
        case .failure(let error):
            return .refused(error.localizedDescription)
        case .success(let bytes):
            return text(of: bytes)
        }
    }

    /// The bytes as text when they are strict JSON (`StrictJSON`): one copy,
    /// and one UTF-8 check, for a file that can be large and change often.
    static func text(of data: Data) -> Outcome {
        let bytes = [UInt8](data)
        guard let text = String(validating: bytes, as: UTF8.self) else { return .refused(notUTF8) }
        return StrictJSON.isValid(utf8: bytes) ? .text(text) : .refused(notJSON)
    }
}
