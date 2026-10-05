import AppKit

/// The menu bar: the standard set the Tauri app shows (its `Menu::default`),
/// plus *Settings…* and, directly above Quit, *Warn Before Quitting*. Tarmac's
/// own commands are keys on the board, not menu items.
@MainActor
enum MainMenu {
    static func build(quitGuard: QuitGuardController, settings: SettingsWindowController) -> NSMenu {
        let name = NSRunningApplication.current.localizedName ?? "Tarmac"
        let main = NSMenu()

        let services = NSMenu()
        NSApp.servicesMenu = services
        let quit = item("Quit \(name)", QuitGuardController.quitAction, "q")
        // Held weakly by the item: the app delegate keeps the guard alive.
        quit.target = quitGuard
        let openSettings = item("Settings…", SettingsWindowController.showAction, ",")
        openSettings.target = settings
        main.addItem(submenu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            openSettings,
            .separator(),
            submenuItem("Services", services),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            quitGuard.warning.menuItem(),
            quit,
        ]))

        main.addItem(submenu("File", [
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))

        main.addItem(submenu("View", [
            item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)

        let help = submenu("Help", [])
        NSApp.helpMenu = help.submenu
        main.addItem(help)

        return main
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        return submenuItem(title, menu)
    }

    private static func submenuItem(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
