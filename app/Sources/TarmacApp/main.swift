import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: AppController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rootView = RootView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "tarmac"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.bg0
        window.contentMinSize = NSSize(width: 1100, height: 700)
        window.center()

        controller = AppController(window: window, rootView: rootView)
        window.contentView = rootView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.focusPrimeTerminal()

        controller.start()
        controller.runPerfBenchmarkIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Fix #2: a settling pan's persist is debounced; flush it when the app
        // loses focus so the last position survives a background/quit-from-Dock.
        controller?.flushPendingPersist()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Fix #2: flush any pending debounced layout persist before tearing down.
        controller?.flushPendingPersist()
        // P5.3: cancel the bounded reconnect loop + close the socket deterministically.
        controller?.shutdown()
    }

    @objc func peekRecentDoc(_ sender: Any?) {
        controller?.peekRecent()
    }

    @objc func pinPeekedDoc(_ sender: Any?) {
        controller?.togglePinPeeked()
    }
}

@MainActor
func buildMainMenu() -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Hide Tarmac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Tarmac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    main.addItem(editItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(withTitle: "Peek Recent Doc", action: #selector(AppDelegate.peekRecentDoc(_:)), keyEquivalent: "p")
    viewMenu.addItem(withTitle: "Pin Peeked Doc", action: #selector(AppDelegate.pinPeekedDoc(_:)), keyEquivalent: "\r")
    viewItem.submenu = viewMenu
    main.addItem(viewItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)

    return main
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: .darkAqua)
app.mainMenu = buildMainMenu()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
