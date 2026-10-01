import Foundation

/// A text resource shipped with the app: the pages and scripts its web views
/// load. Nothing is fetched at run time.
enum BundledResource {
    case docTemplate
    case web(String)

    /// The resource's text. A packaged app carries its resources in
    /// Contents/Resources, where `Bundle.module` finds no package bundle and
    /// traps, so the main bundle is asked first.
    var text: String {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: subdirectory)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: subdirectory),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("missing bundled resource \(name)") }
        return text
    }

    private var name: String {
        switch self {
        case .docTemplate: return "DocTemplate.html"
        case .web(let name): return name
        }
    }

    private var subdirectory: String? {
        switch self {
        case .docTemplate: return nil
        case .web: return "Web"
        }
    }
}
