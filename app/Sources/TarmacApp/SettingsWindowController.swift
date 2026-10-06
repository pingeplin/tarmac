import AppKit
import TarmacKit

/// The Settings window (specs 2610.0005, 2610.0007): a sidebar of the panes
/// and, beside it, the pane that is selected. Both panes are laid out in the
/// window at all times and one is hidden, so the window has one size. The
/// pane it shows is kept for the session: the window is closed, not
/// released.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let showAction = #selector(show(_:))

    private static let sidebarWidth: CGFloat = 180
    private static let margin: CGFloat = 20
    /// The pane's title is level with the window's buttons, where System
    /// Settings has it.
    private static let headingTop: CGFloat = 16

    private let fonts: FontsPane
    private let theme: ThemePane
    private let sidebar = SettingsSidebar()
    private let heading = NSTextField(labelWithString: "")
    private lazy var window = makeWindow()

    init(fonts: FontSettings, theme: ThemeSettings) {
        self.fonts = FontsPane(fonts: fonts)
        self.theme = ThemePane(theme: theme)
    }

    @objc func show(_ sender: Any?) {
        if !window.isVisible {
            fonts.reload()
            theme.reload()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func view(of pane: SettingsPane) -> NSView {
        switch pane {
        case .fonts: fonts.view
        case .theme: theme.view
        }
    }

    private func display(_ pane: SettingsPane) {
        sidebar.select(pane)
        heading.stringValue = pane.title
        for other in SettingsPane.allCases { view(of: other).isHidden = other != pane }
    }

    /// AppKit does not end a field's editing when its window closes: the
    /// typed text would be lost, and still be there when the window opens.
    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
    }

    private func makeWindow() -> NSWindow {
        let content = makeContent()
        let detail = NSViewController()
        detail.view = content
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        // The window has one size, so the sidebar has one too.
        side.canCollapse = false
        side.minimumThickness = Self.sidebarWidth
        side.maximumThickness = Self.sidebarWidth
        let split = NSSplitViewController()
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))

        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // With a toolbar, though it is empty, the sidebar has the window's
        // whole height and holds its buttons, as in System Settings.
        let toolbar = NSToolbar()
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = split
        let size = content.fittingSize
        window.setContentSize(NSSize(width: Self.sidebarWidth + size.width, height: size.height))
        window.center()

        sidebar.onSelect = { [weak self] in self?.display($0) }
        display(.fonts)
        return window
    }

    private func makeContent() -> NSView {
        let content = NSView()
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.headingTop),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
        ])
        for pane in SettingsPane.allCases {
            let paneView = view(of: pane)
            content.addSubview(paneView)
            NSLayoutConstraint.activate([
                paneView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Self.margin),
                paneView.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Self.margin),
                paneView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
                paneView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            ])
        }
        return content
    }
}
