import Foundation
import TarmacKit
import WebKit

/// Answers `tarmac-card://` for every card web view: an HTML card's document
/// and a markdown doc's local images. What to serve is `CardSchemeRouter`'s
/// decision; this reads the file off the main thread and hands the answer to
/// WebKit.
@MainActor
final class CardSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tarmac-card"
    static let shared = CardSchemeHandler()

    private let shim = BundledResource.web("card_shim.js").text
    private let reads = DispatchQueue(label: "tarmac.card-scheme", qos: .userInitiated, attributes: .concurrent)
    /// The tasks WebKit has started and not stopped. Answering a stopped task
    /// raises an exception.
    private var live: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        live[id] = urlSchemeTask
        let shim = self.shim
        reads.async {
            // The whole URL as text: `URL.path` would percent-decode it.
            let response = CardSchemeRouter.respond(url: url.absoluteString, shim: shim, read: FileBytes.read)
            DispatchQueue.main.async { [weak self] in
                self?.finish(id, url: url, with: response)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        live[ObjectIdentifier(urlSchemeTask)] = nil
    }

    private func finish(_ id: ObjectIdentifier, url: URL, with response: CardProtocol.Response) {
        guard let task = live.removeValue(forKey: id) else { return }
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
