import AppKit
import TarmacKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow!
    private(set) var controller: AppController!
    /// The Quit item holds its target weakly; this is what keeps it alive.
    private(set) var quitGuard: QuitGuardController!
    /// The Settings item holds its target weakly too.
    private var settings: SettingsWindowController!
    private let closeHider = WindowCloseHider()
    #if DEBUG
    private let devDriver = DevDriver()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the first view is built: chrome takes its font and its
        // colours at `init`.
        let client = AppController.daemonClient()
        let prefs = AppPrefsStore(path: AppPrefs.path(besideSocket: client.socketPath))
        let fonts = FontSettings(prefs: prefs)
        let theme = ThemeSettings(prefs: prefs)
        let rootView = RootView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "tarmac"
        window.backgroundColor = Theme.bg0
        window.contentMinSize = NSSize(width: 1100, height: 700)
        window.center()
        closeHider.attach(to: window)

        controller = AppController(window: window, rootView: rootView, client: client, fonts: fonts, theme: theme)
        window.contentView = rootView

        quitGuard = QuitGuardController(window: window, warning: WarnBeforeQuit(prefs: prefs))
        settings = SettingsWindowController(fonts: fonts)
        NSApp.mainMenu = MainMenu.build(quitGuard: quitGuard, settings: settings)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.focusPrimeTerminal()

        controller.start()
        #if DEBUG
        scheduleDevSnapshot()
        devDriver.start(DevVerbs(controller: controller, quitGuard: quitGuard, window: window))
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

    /// The red button hides the window (`WindowCloseHider`); a windowless
    /// Tarmac still owns live terminals.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        closeHider.restore()
    }

    /// A Dock click on an already-active Tarmac raises no activation.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        closeHider.restore()
        return true
    }

    func applicationWillResignActive(_ notification: Notification) {
        // A settling pan's persist is debounced; flush it when the app loses
        // focus so the last position survives a background/quit-from-Dock.
        controller?.flushPendingPersist()
    }

    /// The flushed layout is all that is sent on quit: the daemon and its
    /// terminals outlive the app.
    func applicationWillTerminate(_ notification: Notification) {
        controller?.flushPendingPersist()
        controller?.shutdown()
        #if DEBUG
        devDriver.stop()
        #endif
    }
}
