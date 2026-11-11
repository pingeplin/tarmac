import Foundation

/// One read of an HTML card's data file (spec 2611.0002): both files are
/// resolved, the resolved data file must sit beside the resolved HTML file,
/// and that resolved file is the one read. `resolve` and `read` are the
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
    static let notUTF8 = "not UTF-8"
    static let notJSON = "not valid JSON"

    public static func read(
        file: String, html: String,
        resolve: (String) -> Result<String, any Error>, read: (String) -> Result<Data, any Error>
    ) -> Outcome {
        let resolved: String
        let directory: String
        switch (resolve(file), resolve(html)) {
        case (.failure(let error), _):
            return .refused(error.localizedDescription)
        case (_, .failure(let error)):
            return .refused("the card's file: \(error.localizedDescription)")
        case (.success(let data), .success(let card)):
            resolved = data
            directory = CardDataPath.parent(of: card)
        }
        guard CardDataPath.parent(of: resolved) == directory else { return .refused(leadsOutside) }
        switch read(resolved) {
        case .failure(let error):
            return .refused(error.localizedDescription)
        case .success(let bytes):
            return text(of: bytes)
        }
    }

    /// The bytes as text when they are strict JSON (`StrictJSON`).
    static func text(of bytes: Data) -> Outcome {
        guard let text = String(data: bytes, encoding: .utf8) else { return .refused(notUTF8) }
        return StrictJSON.isValid(bytes) ? .text(text) : .refused(notJSON)
    }
}
