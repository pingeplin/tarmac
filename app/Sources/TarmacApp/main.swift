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
        #if DEBUG
        scheduleDevSnapshot()
        #endif
    }

    #if DEBUG
    /// `TARMAC_DEV_SHOT=<path>` writes the window's content view to that PNG
    /// `TARMAC_DEV_SHOT_AFTER` seconds after launch (default 4);
    /// `TARMAC_DEV_SHOT_QUIT` then quits.
    private func scheduleDevSnapshot() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TARMAC_DEV_SHOT"] else { return }
        let delay = environment["TARMAC_DEV_SHOT_AFTER"].flatMap(Double.init) ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if let view = self?.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if environment["TARMAC_DEV_SHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }
    #endif

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
