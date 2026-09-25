//
//  ProcessControl.swift
//  OpenActivity
//
//  Quitting apps, processes and dev servers. Nothing is ever stopped without a confirmation.
//

import AppKit

enum ProcessControl {
    /// Asks, then quits every process of the app. Force quitting skips the app's own save prompts.
    static func quit(_ app: AppGroup, force: Bool, window: NSWindow?, completion: (() -> Void)? = nil) {
        guard app.id != AppGrouper.systemGroupID else {
            let alert = NSAlert()
            alert.messageText = "macOS processes can't be quit as a group"
            alert.informativeText = "Expand the group and quit a single process instead. Quitting system processes can make your Mac unstable."
            present(alert, window: window) { _ in }
            return
        }
        let alert = NSAlert()
        alert.icon = AppIcons.icon(for: app)
        alert.messageText = force ? "Force quit \(app.name)?" : "Quit \(app.name)?"
        let count = app.processes.count
        var info = count == 1 ? "Its process will close." : "All \(Format.number(count)) of its processes will close."
        if force { info += " Unsaved changes will be lost." }
        alert.informativeText = info
        alert.addButton(withTitle: force ? "Force Quit" : "Quit")
        alert.addButton(withTitle: "Cancel")
        if force { alert.buttons.first?.hasDestructiveAction = true }

        present(alert, window: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            perform(app, force: force)
            completion?()
        }
    }

    static func quit(_ process: ProcessSample, force: Bool, window: NSWindow?, completion: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = force ? "Force quit “\(process.name)”?" : "Quit “\(process.name)”?"
        var info = "Process \(process.pid)"
        if process.memory > 0 { info += " · \(Format.memory(process.memory))" }
        if process.uid == 0 || !process.isAccessible {
            info += "\n\nThis process belongs to macOS or another user. You may not have permission to quit it."
        }
        alert.informativeText = info
        alert.addButton(withTitle: force ? "Force Quit" : "Quit")
        alert.addButton(withTitle: "Cancel")
        if force { alert.buttons.first?.hasDestructiveAction = true }

        present(alert, window: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if let problem = signal(process.pid, startTime: process.startTime, force: force) {
                let failure = NSAlert()
                failure.messageText = "Couldn't quit “\(process.name)”"
                failure.informativeText = problem
                present(failure, window: window) { _ in }
            }
            completion?()
        }
    }

    /// Stops dev servers: SIGTERM first, SIGKILL for anything still running three seconds later.
    static func stop(_ processes: [DevProcess], title: String, window: NSWindow?, completion: @escaping (_ freed: UInt64, _ ports: [UInt16]) -> Void) {
        guard !processes.isEmpty else { return }
        let freed = processes.reduce(0) { $0 + $1.memory }
        let ports = processes.flatMap(\.ports).sorted()
        let alert = NSAlert()
        alert.messageText = title
        var info = "Frees \(Format.memory(freed))"
        if !ports.isEmpty {
            info += " and " + (ports.count == 1 ? "port " : "ports ") + ports.map(String.init).joined(separator: ", ")
        }
        info += ". Unsaved work in these processes is lost."
        alert.informativeText = info
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")

        present(alert, window: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            processes.forEach { signal($0.pid, startTime: $0.startTime, force: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                // The start-time check keeps a pid that was reused meanwhile from being killed.
                processes.forEach { signal($0.pid, startTime: $0.startTime, force: true) }
                Monitor.shared.refreshNow()
            }
            completion(freed, ports)
        }
    }

    private static func perform(_ app: AppGroup, force: Bool) {
        var handled = Set<Int32>()
        if let identifier = app.bundleIdentifier {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
                handled.insert(running.processIdentifier)
                _ = force ? running.forceTerminate() : running.terminate()
            }
        }
        // Helpers usually exit with their app; signal the rest directly (and everything for command-line tools).
        let remaining = app.processes.filter { !handled.contains($0.pid) }
        if handled.isEmpty {
            remaining.forEach { signal($0.pid, startTime: $0.startTime, force: force) }
        } else if force {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                remaining.forEach { signal($0.pid, startTime: $0.startTime, force: true) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Monitor.shared.refreshNow() }
    }

    /// Sends the quit request. Returns nil on success, otherwise why it failed.
    @discardableResult
    private static func signal(_ pid: Int32, startTime: Date?, force: Bool) -> String? {
        // kill(0) would signal our own process group, and quitting ourselves from a list is never meant.
        guard pid > 0, pid != getpid() else { return "This process can't be quit from OpenActivity." }
        guard let started = processStartTime(pid) else { return "The process has already quit." }
        if let startTime, Int(started.timeIntervalSince1970) != Int(startTime.timeIntervalSince1970) {
            return "The process has already quit."
        }
        if let running = NSRunningApplication(processIdentifier: pid), running.bundleIdentifier != nil {
            let accepted = force ? running.forceTerminate() : running.terminate()
            return accepted ? nil : "The app didn't accept the request to quit."
        }
        guard kill(pid, force ? SIGKILL : SIGTERM) != 0 else { return nil }
        let code = errno
        return code == EPERM ? "You don't have permission to quit this process." : String(cString: strerror(code))
    }

    /// When the process with this pid started, or nil if no such process exists.
    private static func processStartTime(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.kp_proc.p_un.__p_starttime.tv_sec))
    }

    private static func present(_ alert: NSAlert, window: NSWindow?, handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handler(alert.runModal())
        }
    }
}
