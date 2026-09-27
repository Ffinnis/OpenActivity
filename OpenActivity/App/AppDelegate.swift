//
//  AppDelegate.swift
//  OpenActivity
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var mainWindowController: MainWindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AlertSettings.registerDefaults()
        let preferences = Preferences.shared
        NSApp.setActivationPolicy(preferences.showDockIcon ? .regular : .accessory)
        NSApp.mainMenu = MainMenu.build()

        Monitor.shared.start()
        statusItemController = StatusItemController()

        AlertEngine.shared.onOpen = { [weak self] metric, _ in
            self?.showMainWindow(page: metric)
        }
        AlertEngine.shared.requestAuthorizationIfNeeded()
        _ = AudioVolumeController.shared

        if preferences.showDockIcon {
            showMainWindow(page: nil)
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.showSettings") {
            SettingsWindowController.shared.show()
        }
        // Demo recordings: shell tools drive the UI with a distributed notification named
        // "roman.potapov.OpenActivity.demo" whose object is "page:cpu", "popover", "stopIdle",
        // "scroll:end", "scroll:top", "alert:Xcode" or "memalert:Slack".
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("roman.potapov.OpenActivity.demo"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let command = note.object as? String else { return }
            let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "page": if parts.count == 2, let page = Metric(rawValue: parts[1]) { self?.mainWindowController?.show(page) }
            case "alert": if parts.count == 2 { AlertEngine.shared.postDemoAlert(appName: parts[1], averageCPU: 87) }
            case "memalert": if parts.count == 2 { AlertEngine.shared.postDemoMemoryAlert(appName: parts[1], grownGB: 2.4, nowGB: 3.9) }
            case "scroll": self?.mainWindowController?.demoScroll(toEnd: parts.count < 2 || parts[1] != "top")
            default: NotificationCenter.default.post(name: Notification.Name("OpenActivityDemo.\(parts[0])"), object: nil)
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(page: nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Windows

    func showMainWindow(page: Metric?) {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        if let page { mainWindowController?.show(page) }
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var mainWindow: NSWindow? { mainWindowController?.window }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showMainWindowAction(_ sender: Any?) {
        showMainWindow(page: nil)
    }

    @objc func showPage(_ sender: NSMenuItem) {
        guard let metric = sender.representedObject as? String, let page = Metric(rawValue: metric) else { return }
        showMainWindow(page: page)
    }

    @objc func exportShareCardLight(_ sender: Any?) { exportShareCard(dark: false) }
    @objc func exportShareCardDark(_ sender: Any?) { exportShareCard(dark: true) }

    private func exportShareCard(dark: Bool) {
        guard Monitor.shared.hasSample else { return }
        do {
            let url = try ShareCard.exportToDownloads(snapshot: Monitor.shared.snapshot, dark: dark)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func copyShareCard(_ sender: Any?) {
        guard Monitor.shared.hasSample else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = ShareCard.render(snapshot: Monitor.shared.snapshot, dark: dark)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc func copyDashboard(_ sender: Any?) {
        showMainWindow(page: .overview)
        mainWindowController?.copyDashboardImage()
    }

    @objc func toggleSystemProcesses(_ sender: Any?) {
        Preferences.shared.showSystemProcesses.toggle()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSystemProcesses(_:)) {
            menuItem.state = Preferences.shared.showSystemProcesses ? .on : .off
        }
        return true
    }
}
