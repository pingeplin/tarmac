import Foundation
import TarmacKit
import WebKit

/// Answers `tarmac-card://` for the card web views of one kind: an HTML
/// card's document, or a markdown doc's local images. What to serve is
/// `CardSchemeRouter`'s decision; this reads the file off the main thread and
/// hands the answer to WebKit.
@MainActor
final class CardSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tarmac-card"
    /// For HTML cards: the `doc` host only.
    static let cards = CardSchemeHandler(serving: .doc)
    /// For markdown docs: the `img` host only.
    static let docImages = CardSchemeHandler(serving: .img)

    private let host: CardURL.Host
    private let shim = BundledResource.web("card_shim.js").text
    private let reads = DispatchQueue(label: "tarmac.card-scheme", qos: .userInitiated, attributes: .concurrent)
    /// The tasks WebKit has started and not stopped. Answering a stopped task
    /// raises an exception, and a stopped task's address may by then belong to
    /// another.
    private var pending = PendingReads<ObjectIdentifier, any WKURLSchemeTask>()

    private init(serving host: CardURL.Host) {
        self.host = host
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let ticket = pending.start(ObjectIdentifier(urlSchemeTask), for: urlSchemeTask)
        let headers = urlSchemeTask.request.allHTTPHeaderFields ?? [:]
        let shim = self.shim
        let host = self.host
        reads.async { [weak self] in
            // The whole URL as text: `URL.path` would percent-decode it.
            let response = CardSchemeRouter.respond(
                url: url.absoluteString, headers: headers, shim: shim, serving: host,
                read: FileBytes.read, resolve: FileBytes.resolved
            )
            DispatchQueue.main.async { [weak self] in
                self?.finish(ticket, url: url, with: response)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        pending.stop(ObjectIdentifier(urlSchemeTask))
    }

    private func finish(
        _ ticket: PendingReads<ObjectIdentifier, any WKURLSchemeTask>.Ticket, url: URL,
        with response: CardProtocol.Response
    ) {
        guard let task = pending.finish(ticket) else { return }
        guard let head = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers
        ) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(head)
        task.didReceive(response.body)
        task.didFinish()
    }
}
