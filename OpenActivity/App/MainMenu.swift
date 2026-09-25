//
//  MainMenu.swift
//  OpenActivity
//
//  The menu bar menus, built in code since the app has no storyboard.
//

import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let main = NSMenu()

        main.addItem(submenu("", items: [
            NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ","),
            .separator(),
            servicesItem(),
            .separator(),
            NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]))

        main.addItem(submenu("File", items: [
            NSMenuItem(title: "Open Main Window", action: #selector(AppDelegate.showMainWindowAction(_:)), keyEquivalent: "0"),
            .separator(),
            NSMenuItem(title: "Export Share Card (Light)", action: #selector(AppDelegate.exportShareCardLight(_:)), keyEquivalent: "e"),
            item("Export Share Card (Dark)", #selector(AppDelegate.exportShareCardDark(_:)), "e", [.command, .option]),
            item("Copy Share Card", #selector(AppDelegate.copyShareCard(_:)), "c", [.command, .option]),
            item("Copy Dashboard as Image", #selector(AppDelegate.copyDashboard(_:)), "c", [.command, .shift]),
            .separator(),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ]))

        main.addItem(submenu("Edit", items: [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            .separator(),
            item("Find", #selector(MainWindowController.focusSearch(_:)), "f", [.command]),
        ]))

        var viewItems: [NSMenuItem] = []
        let pages: [Metric] = [.overview, .cpu, .memory, .disk, .network, .gpu, .battery, .sensors, .sound, .projects]
        for (index, page) in pages.enumerated() {
            let key = index < 9 ? "\(index + 1)" : ""
            let pageItem = NSMenuItem(title: page.title, action: #selector(AppDelegate.showPage(_:)), keyEquivalent: key)
            pageItem.representedObject = page.rawValue
            viewItems.append(pageItem)
        }
        viewItems.append(.separator())
        viewItems.append(item("Show macOS Processes", #selector(AppDelegate.toggleSystemProcesses(_:)), "p", [.command, .option]))
        viewItems.append(.separator())
        viewItems.append(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        main.addItem(submenu("View", items: viewItems))

        let window = submenu("Window", items: [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu("Help", items: [])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }
}
