import AppKit

/// A view that lays out a markdown card's sidebar (spec 2611.0025 D16): it
/// takes the side again when `Theme.docSidebarSide` changes.
@MainActor
protocol DocSidebarSideFollowing: NSView {
    func docSidebarSideChanged()
}

extension NSView {
    func broadcastDocSidebarSideChanged() {
        tellTree { ($0 as? any DocSidebarSideFollowing)?.docSidebarSideChanged() }
    }
}
