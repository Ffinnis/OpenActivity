//
//  AlertEngine.swift
//  OpenActivity
//
//  Watches every app over rolling windows and posts a notification when one misbehaves:
//  keeps the CPU busy, grows its memory steadily, writes to disk or uses the network heavily
//  for minutes on end, or when the whole Mac has been under critical memory pressure.
//
//  Which apps are watched:
//    - OpenActivity itself and kernel_task are never reported.
//    - Apps macOS runs by itself (`AppGroup.isSystem`) are skipped for CPU, disk and network:
//      indexing, backups and updates legitimately spike and there is nothing the user can do.
//    - They are still watched for memory growth, one process at a time, because a leaking
//      system process is worth knowing about and fixed by a restart. macOS only reports memory
//      for processes running under the user's account, so daemons owned by root or another
//      user (WindowServer, for example) read as zero and cannot be watched.
//

import Foundation
import UserNotifications

/// Alert preferences, stored in `UserDefaults.standard`.
struct AlertSettings {
    var enabled: Bool
    var cpu: Bool
    /// Percent of one core.
    var cpuThreshold: Double
    var cpuMinutes: Int
    var memory: Bool
    /// Growth within one hour, in GB (2^30 bytes, as `ByteCountFormatter` shows memory).
    var memoryGrowthGB: Double
    var disk: Bool
    /// Sustained writes over 5 minutes, in MB/s (2^20 bytes).
    var diskMBps: Double
    var network: Bool
    /// Sustained traffic (in + out) over 5 minutes, in MB/s (2^20 bytes).
    var networkMBps: Double
    /// Memory pressure critical for 2 minutes.
    var systemMemory: Bool

    private enum Key {
        static let enabled = "alerts.enabled"
        static let cpu = "alerts.cpu"
        static let cpuThreshold = "alerts.cpuThreshold"
        static let cpuMinutes = "alerts.cpuMinutes"
        static let memory = "alerts.memory"
        static let memoryGrowthGB = "alerts.memoryGrowthGB"
        static let disk = "alerts.disk"
        static let diskMBps = "alerts.diskMBps"
        static let network = "alerts.network"
        static let networkMBps = "alerts.networkMBps"
        static let systemMemory = "alerts.systemMemory"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.enabled: true,
            Key.cpu: true, Key.cpuThreshold: 70.0, Key.cpuMinutes: 10,
            Key.memory: true, Key.memoryGrowthGB: 1.0,
            Key.disk: true, Key.diskMBps: 50.0,
            Key.network: true, Key.networkMBps: 10.0,
            Key.systemMemory: true,
        ])
    }

    private static let defaultsRegistered: Void = registerDefaults()

    /// Values are clamped to sane ranges so a bad preference can't make every sample alert.
    static func load() -> AlertSettings {
        _ = defaultsRegistered
        let defaults = UserDefaults.standard
        return AlertSettings(
            enabled: defaults.bool(forKey: Key.enabled),
            cpu: defaults.bool(forKey: Key.cpu),
            cpuThreshold: max(5, defaults.double(forKey: Key.cpuThreshold)),
            cpuMinutes: min(120, max(1, defaults.integer(forKey: Key.cpuMinutes))),
            memory: defaults.bool(forKey: Key.memory),
            memoryGrowthGB: max(0.1, defaults.double(forKey: Key.memoryGrowthGB)),
            disk: defaults.bool(forKey: Key.disk),
            diskMBps: max(1, defaults.double(forKey: Key.diskMBps)),
            network: defaults.bool(forKey: Key.network),
            networkMBps: max(0.1, defaults.double(forKey: Key.networkMBps)),
            systemMemory: defaults.bool(forKey: Key.systemMemory))
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(cpu, forKey: Key.cpu)
        defaults.set(cpuThreshold, forKey: Key.cpuThreshold)
        defaults.set(cpuMinutes, forKey: Key.cpuMinutes)
        defaults.set(memory, forKey: Key.memory)
        defaults.set(memoryGrowthGB, forKey: Key.memoryGrowthGB)
        defaults.set(disk, forKey: Key.disk)
        defaults.set(diskMBps, forKey: Key.diskMBps)
        defaults.set(network, forKey: Key.network)
        defaults.set(networkMBps, forKey: Key.networkMBps)
        defaults.set(systemMemory, forKey: Key.systemMemory)
    }
}

/// A posted alert. System-wide alerts use the app id `AlertEngine.systemAppID`.
struct AppAlert {
    var appID: String
    var appName: String
    var metric: Metric
    var title: String
    var body: String
    var date: Date
}

/// Thread-safe: evaluation state and `recentAlerts` are guarded by a lock; `onOpen` is main-thread only.
final class AlertEngine: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = AlertEngine()

    /// Posted on the main thread whenever `recentAlerts` changes.
    static let recentAlertsDidChange = Notification.Name("AlertEngine.recentAlertsDidChange")
    /// `AppAlert.appID` of alerts about the whole Mac.
    static let systemAppID = "system"

    /// Called on the main thread when the user clicks an alert notification.
    /// The app id is nil for system-wide alerts.
    var onOpen: ((Metric, String?) -> Void)?

    /// Recent alerts, newest first, at most 50.
    private(set) var recentAlerts: [AppAlert] {
        get { lock.withLock { recent } }
        set { lock.withLock { recent = newValue } }
    }

    /// Apps with evaluation state; exposed for tests.
    var trackedAppCount: Int { lock.withLock { apps.count } }

    static let cooldown: TimeInterval = 60 * 60
    static let sustainedWindow: TimeInterval = 5 * 60
    static let memoryWindow: TimeInterval = 60 * 60
    static let criticalPressureDuration: TimeInterval = 2 * 60
    /// Apps not seen for this long are forgotten.
    static let forgetAfter: TimeInterval = 2 * 60

    private let lock = NSLock()
    private var recent: [AppAlert] = []
    // Evaluation state, guarded by `lock`.
    private var apps: [String: AppState] = [:]
    private var lastAlerts: [String: TimeInterval] = [:]
    private var criticalSince: TimeInterval?

    /// UNUserNotificationCenter raises an exception outside an app bundle (tests, command-line runs).
    private let canNotify = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let ownBundleID = Bundle.main.bundleIdentifier

    override init() {
        super.init()
        // Set early so a click that launches the app is still delivered.
        if canNotify { UNUserNotificationCenter.current().delegate = self }
    }

    func requestAuthorizationIfNeeded() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { NSLog("AlertEngine: notification authorization failed: %@", error.localizedDescription) }
            }
        }
    }

    /// Called on the Monitor's background queue after each sample.
    func evaluate(_ snapshot: SystemSnapshot) {
        let settings = AlertSettings.load()
        let now = snapshot.date.timeIntervalSince1970

        lock.lock()
        guard settings.enabled else {
            apps.removeAll()
            criticalSince = nil
            lock.unlock()
            return
        }
        var alerts: [AppAlert] = []
        let cpuWindow = TimeInterval(settings.cpuMinutes) * 60

        for group in alertUnits(snapshot) {
            var cpu = 0.0, memory = 0.0, diskWrite = 0.0, network = 0.0
            for process in group.processes {
                cpu += process.cpuPercent
                memory += Double(process.memory)
                diskWrite += process.diskWriteRate
                network += process.netInRate + process.netOutRate
            }
            var state = apps[group.id] ?? AppState()
            state.lastSeen = now
            state.memory.add(memory, at: now)
            if !group.isSystem {
                state.cpu.span = cpuWindow
                state.cpu.add(cpu, at: now)
                state.diskWrite.add(diskWrite, at: now)
                state.network.add(network, at: now)
            }

            if !group.isSystem, settings.cpu, let alert = cpuAlert(group, state, settings, window: cpuWindow, now: now) {
                alerts.append(alert)
            }
            if settings.memory, let alert = memoryAlert(group, state, current: memory, settings, now: now) {
                alerts.append(alert)
            }
            if !group.isSystem, settings.disk, let alert = diskAlert(group, state, settings, now: now) {
                alerts.append(alert)
            }
            if !group.isSystem, settings.network, let alert = networkAlert(group, state, settings, now: now) {
                alerts.append(alert)
            }
            apps[group.id] = state
        }

        if let alert = systemMemoryAlert(snapshot, settings, now: now) { alerts.append(alert) }

        // Forget apps that quit and cooldowns that ran out.
        apps = apps.filter { now - $0.value.lastSeen <= Self.forgetAfter && $0.value.lastSeen <= now }
        lastAlerts = lastAlerts.filter { now - $0.value < Self.cooldown && $0.value <= now }
        lock.unlock()

        for alert in alerts { post(alert) }
    }

    // MARK: - Rules (called with `lock` held)

    private func cpuAlert(_ group: AppGroup, _ state: AppState, _ settings: AlertSettings, window: TimeInterval, now: TimeInterval) -> AppAlert? {
        guard let (average, covered) = state.cpu.average(over: window, now: now),
              covered >= 0.9 * window, average >= settings.cpuThreshold,
              claimCooldown(group.id, .cpu, now: now) else { return nil }
        var body = "It has averaged \(Self.percent(average)) CPU for the last \(Self.minutes(window))"
        if average >= 200 { body += ", as much as \(Int((average / 100).rounded(.down))) fully busy cores" }
        return AppAlert(appID: group.id, appName: group.name, metric: .cpu,
                        title: "\(group.name) is keeping the CPU busy", body: body + ".", date: Date(timeIntervalSince1970: now))
    }

    /// Growth of at least the limit within the hour, with the app watched for at least half an hour
    /// (so launching doesn't count), still near its peak and still rising over the last 20 minutes.
    private func memoryAlert(_ group: AppGroup, _ state: AppState, current: Double, _ settings: AlertSettings, now: TimeInterval) -> AppAlert? {
        let limit = settings.memoryGrowthGB * 1_073_741_824
        guard let lowest = state.memory.minimum(over: Self.memoryWindow, now: now),
              let highest = state.memory.maximum(over: Self.memoryWindow, now: now),
              let recentLowest = state.memory.minimum(over: 20 * 60, now: now),
              state.memory.covered(over: Self.memoryWindow, now: now) >= Self.memoryWindow / 2,
              current - lowest.value >= limit,
              current >= 0.95 * highest,
              current - recentLowest.value >= 0.2 * limit,
              claimCooldown(group.id, .memory, now: now) else { return nil }
        let elapsed = now - lowest.time
        let span = elapsed >= 55 * 60 ? "the last hour" : "the last \(Self.minutes(elapsed))"
        return AppAlert(appID: group.id, appName: group.name, metric: .memory,
                        title: "\(Self.possessive(group.name)) memory keeps growing",
                        body: "Up \(Self.bytes(current - lowest.value)) in \(span), now \(Self.bytes(current)).",
                        date: Date(timeIntervalSince1970: now))
    }

    private func diskAlert(_ group: AppGroup, _ state: AppState, _ settings: AlertSettings, now: TimeInterval) -> AppAlert? {
        let window = Self.sustainedWindow
        guard let (rate, covered) = state.diskWrite.average(over: window, now: now),
              covered >= 0.9 * window, rate >= settings.diskMBps * 1_048_576,
              claimCooldown(group.id, .disk, now: now) else { return nil }
        return AppAlert(appID: group.id, appName: group.name, metric: .disk,
                        title: "\(group.name) is writing a lot to disk",
                        body: "It has written \(Self.bytes(rate * covered)) in the last \(Self.minutes(window)), about \(Self.bytes(rate))/s.",
                        date: Date(timeIntervalSince1970: now))
    }

    private func networkAlert(_ group: AppGroup, _ state: AppState, _ settings: AlertSettings, now: TimeInterval) -> AppAlert? {
        let window = Self.sustainedWindow
        guard let (rate, covered) = state.network.average(over: window, now: now),
              covered >= 0.9 * window, rate >= settings.networkMBps * 1_048_576,
              claimCooldown(group.id, .network, now: now) else { return nil }
        return AppAlert(appID: group.id, appName: group.name, metric: .network,
                        title: "\(group.name) is using a lot of network",
                        body: "It has transferred \(Self.bytes(rate * covered)) in the last \(Self.minutes(window)), about \(Self.bytes(rate))/s.",
                        date: Date(timeIntervalSince1970: now))
    }

    private func systemMemoryAlert(_ snapshot: SystemSnapshot, _ settings: AlertSettings, now: TimeInterval) -> AppAlert? {
        guard snapshot.memory.pressure == .critical else {
            criticalSince = nil
            return nil
        }
        let since = criticalSince ?? now
        criticalSince = since
        guard settings.systemMemory, now - since >= Self.criticalPressureDuration,
              claimCooldown(Self.systemAppID, .systemMemory, now: now) else { return nil }
        var body = "Memory pressure has been critical for \(Self.minutes(now - since))."
        if let top = snapshot.apps.filter({ !isOwnApp($0) && $0.id != AppGrouper.systemGroupID }).max(by: { $0.memory < $1.memory }) {
            body += " \(top.name) is using the most, \(Self.bytes(Double(top.memory)))."
        }
        return AppAlert(appID: Self.systemAppID, appName: "macOS", metric: .memory,
                        title: "Your Mac is running out of memory", body: body, date: Date(timeIntervalSince1970: now))
    }

    /// Only our own bundle. When OpenActivity is started from a terminal or an editor it is grouped
    /// under that app, which must still be watched; our pid is dropped from the sums instead.
    private func isOwnApp(_ group: AppGroup) -> Bool {
        guard let ownBundleID else { return false }
        return group.bundleIdentifier == ownBundleID
    }

    /// What gets its own rolling windows: every app, plus each sizeable macOS process on its own.
    /// Summing hundreds of daemons would hide one that leaks and flag ordinary churn instead.
    private func alertUnits(_ snapshot: SystemSnapshot) -> [AppGroup] {
        var units: [AppGroup] = []
        for group in snapshot.apps where !isOwnApp(group) {
            let processes = group.processes.filter { $0.pid > 0 && $0.pid != ownPID }
            guard !processes.isEmpty else { continue }
            if group.id == AppGrouper.systemGroupID {
                for process in processes where process.memory >= Self.systemProcessMemoryFloor {
                    let start = Int(process.startTime?.timeIntervalSince1970 ?? 0)
                    units.append(AppGroup(id: "macos:\(process.pid):\(start)", name: process.name, bundlePath: nil,
                                          bundleIdentifier: nil, isSystem: true, processes: [process]))
                }
            } else {
                var unit = group
                unit.processes = processes
                units.append(unit)
            }
        }
        return units
    }

    /// macOS processes smaller than this are not watched individually.
    private static let systemProcessMemoryFloor: UInt64 = 100 * 1_048_576

    /// True (and starts the cooldown) when this kind of alert for the app is not cooling down.
    private func claimCooldown(_ appID: String, _ kind: Kind, now: TimeInterval) -> Bool {
        let key = "\(kind.rawValue)|\(appID)"
        if let last = lastAlerts[key], now - last < Self.cooldown, last <= now { return false }
        lastAlerts[key] = now
        return true
    }

    // MARK: - Delivery

    private func post(_ alert: AppAlert) {
        lock.withLock {
            recent.insert(alert, at: 0)
            if recent.count > 50 { recent.removeLast(recent.count - 50) }
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.recentAlertsDidChange, object: self)
        }
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.appID
        var info: [String: String] = ["metric": alert.metric.rawValue]
        if alert.appID != Self.systemAppID { info["appID"] = alert.appID }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("AlertEngine: cannot post notification: %@", error.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let metric = (info["metric"] as? String).flatMap(Metric.init(rawValue:)) ?? .overview
        let appID = info["appID"] as? String
        DispatchQueue.main.async { self.onOpen?(metric, appID) }
        completionHandler()
    }

    // MARK: - Formatting

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    private static func bytes(_ value: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(max(0, value).rounded()))
    }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private static func minutes(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes == 1 ? "minute" : "\(minutes) minutes"
    }

    private static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "'" : name + "'s"
    }
}

// MARK: - Rolling windows

private enum Kind: String {
    case cpu, memory, disk, network, systemMemory
}

private struct AppState {
    var lastSeen: TimeInterval = 0
    var cpu = RollingWindow(slot: 15, span: 10 * 60)
    var memory = RollingWindow(slot: 60, span: AlertEngine.memoryWindow)
    var diskWrite = RollingWindow(slot: 15, span: AlertEngine.sustainedWindow)
    var network = RollingWindow(slot: 15, span: AlertEngine.sustainedWindow)
}

/// Samples folded into fixed-width time slots, oldest first, trimmed to `span`.
/// A window of an hour at one-minute slots holds 60 small structs regardless of the sample rate.
private struct RollingWindow {
    struct Slot {
        var start: TimeInterval
        var sum: Double
        var count: Int
        var min: Double
        var minTime: TimeInterval
        var max: Double
    }

    let slot: TimeInterval
    var span: TimeInterval
    private(set) var slots: [Slot] = []

    init(slot: TimeInterval, span: TimeInterval) {
        self.slot = slot
        self.span = span
    }

    mutating func add(_ value: Double, at time: TimeInterval) {
        guard value.isFinite else { return }
        let start = (time / slot).rounded(.down) * slot
        if let last = slots.indices.last, slots[last].start == start {
            slots[last].sum += value
            slots[last].count += 1
            if value < slots[last].min { slots[last].min = value; slots[last].minTime = time }
            slots[last].max = Swift.max(slots[last].max, value)
        } else if slots.last.map({ $0.start < start }) ?? true {
            slots.append(Slot(start: start, sum: value, count: 1, min: value, minTime: time, max: value))
        } else {
            // The clock went backwards: start over rather than mix timelines.
            slots = [Slot(start: start, sum: value, count: 1, min: value, minTime: time, max: value)]
        }
        let cutoff = time - span
        if let keep = slots.firstIndex(where: { $0.start + slot > cutoff }), keep > 0 {
            slots.removeFirst(keep)
        }
    }

    /// Slots overlapping the last `seconds`.
    private func recent(_ seconds: TimeInterval, now: TimeInterval) -> ArraySlice<Slot> {
        let cutoff = now - seconds
        let first = slots.firstIndex { $0.start + slot > cutoff } ?? slots.endIndex
        return slots[first...]
    }

    /// Time actually observed within the last `seconds` (slots with samples × slot width).
    func covered(over seconds: TimeInterval, now: TimeInterval) -> TimeInterval {
        Swift.min(seconds, Double(recent(seconds, now: now).count) * slot)
    }

    /// Mean of the samples within the last `seconds` and the time they cover.
    func average(over seconds: TimeInterval, now: TimeInterval) -> (value: Double, covered: TimeInterval)? {
        let window = recent(seconds, now: now)
        let count = window.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        return (window.reduce(0) { $0 + $1.sum } / Double(count), covered(over: seconds, now: now))
    }

    func minimum(over seconds: TimeInterval, now: TimeInterval) -> (value: Double, time: TimeInterval)? {
        recent(seconds, now: now).min { $0.min < $1.min }.map { ($0.min, $0.minTime) }
    }

    func maximum(over seconds: TimeInterval, now: TimeInterval) -> Double? {
        recent(seconds, now: now).map(\.max).max()
    }
}
