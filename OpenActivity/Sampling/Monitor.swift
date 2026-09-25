//
//  Monitor.swift
//  OpenActivity
//
//  Runs every sampler on one background queue and publishes a SystemSnapshot to the main thread.
//  Samples every five seconds in the background and faster while a window or the menu is open.
//

import AppKit
import IOKit
import SystemConfiguration

/// A short in-memory history for live graphs, one value per sample.
struct RecentSeries {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 150) { self.capacity = capacity }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    var last: Double { values.last ?? 0 }
    var max: Double { values.max() ?? 0 }
}

struct RecentHistory {
    var cpu = RecentSeries()
    var cpuUser = RecentSeries()
    var cpuSystem = RecentSeries()
    var memory = RecentSeries()
    var gpu = RecentSeries()
    var diskRead = RecentSeries()
    var diskWrite = RecentSeries()
    var netIn = RecentSeries()
    var netOut = RecentSeries()
    var power = RecentSeries()
    var battery = RecentSeries()
    var temperature = RecentSeries()

    mutating func append(_ snapshot: SystemSnapshot) {
        cpu.append(snapshot.cpu.total)
        cpuUser.append(snapshot.cpu.user)
        cpuSystem.append(snapshot.cpu.system)
        memory.append(snapshot.memory.usedFraction)
        gpu.append(snapshot.gpu.utilization)
        diskRead.append(snapshot.disk.readRate)
        diskWrite.append(snapshot.disk.writeRate)
        netIn.append(snapshot.network.inRate)
        netOut.append(snapshot.network.outRate)
        power.append(snapshot.battery.systemPower)
        battery.append(snapshot.battery.charge)
        temperature.append(snapshot.sensors.cpuTemperature ?? 0)
    }
}

final class Monitor {
    static let shared = Monitor()

    struct Token: Hashable { fileprivate let id = UUID() }

    /// The latest snapshot. Main thread only.
    private(set) var snapshot = SystemSnapshot()
    private(set) var recent = RecentHistory()
    private(set) var hasSample = false

    private var observers: [Token: (SystemSnapshot) -> Void] = [:]
    private var interactiveReasons = Set<String>()

    private let queue = DispatchQueue(label: "com.openactivity.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 5

    // Owned by `queue`, and created there on first use: some (SMC key enumeration in particular)
    // take tens of milliseconds to set up, which would otherwise stall launch on the main thread.
    private lazy var cpuSampler = CPUSampler()
    private lazy var memorySampler = MemorySampler()
    private lazy var processSampler = ProcessSampler()
    private lazy var grouper = AppGrouper()
    private lazy var projectDetector = ProjectDetector()
    private lazy var diskSampler = DiskSampler()
    private lazy var networkSampler = NetworkSampler()
    private lazy var gpuSampler = GPUSampler()
    private lazy var batterySampler = BatterySampler()
    private lazy var sensorSampler = SensorSampler()
    private lazy var peripheralSampler = PeripheralBatterySampler()
    private let processNetwork = ProcessNetworkSampler(interval: 2)
    private var tick = 0
    private var lastSensors = SensorStats()
    private var lastPeripherals: [PeripheralBattery] = []
    private var lastProjects: [DevProject] = []

    private lazy var machineName: String = {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }()

    static let interactiveInterval: TimeInterval = 2
    static let backgroundInterval: TimeInterval = 5

    func start() {
        guard timer == nil else { return }
        processNetwork.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.processNetwork.stop()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshNow()
        }
        schedule()
    }

    /// Faster sampling while something on screen shows live figures.
    func setInteractive(_ interactive: Bool, reason: String) {
        if interactive { interactiveReasons.insert(reason) } else { interactiveReasons.remove(reason) }
        let wanted = interactiveReasons.isEmpty ? Self.backgroundInterval : Self.interactiveInterval
        guard wanted != interval else { return }
        interval = wanted
        schedule()
    }

    func refreshNow() {
        queue.async { [weak self] in self?.sampleOnQueue() }
    }

    @discardableResult
    func observe(_ block: @escaping (SystemSnapshot) -> Void) -> Token {
        let token = Token()
        observers[token] = block
        if hasSample { block(snapshot) }
        return token
    }

    func removeObserver(_ token: Token) {
        observers[token] = nil
    }

    private func schedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in self?.sampleOnQueue() }
        timer.resume()
        self.timer = timer
    }

    private func sampleOnQueue() {
        tick += 1
        var snapshot = SystemSnapshot()
        snapshot.date = Date()
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.machineName = machineName
        snapshot.cpu = cpuSampler.sample()
        snapshot.memory = memorySampler.sample()
        snapshot.disk = diskSampler.sample()
        snapshot.network = networkSampler.sample()
        snapshot.battery = batterySampler.sample()

        let gpu = gpuSampler.sample()
        snapshot.gpu = gpu.stats

        // Temperatures and accessory batteries change slowly.
        if tick % 2 == 1 { lastSensors = sensorSampler.sample() }
        if tick % 6 == 1 { lastPeripherals = peripheralSampler.sample() }
        snapshot.sensors = lastSensors
        snapshot.peripherals = lastPeripherals

        var processes = processSampler.sample()
        let network = processNetwork.rates()
        for index in processes.indices {
            let pid = processes[index].pid
            if let rates = network[pid] {
                processes[index].netInRate = rates.inRate
                processes[index].netOutRate = rates.outRate
            }
            if let gpuPercent = gpu.perProcess[pid] {
                processes[index].gpuPercent = gpuPercent
            }
        }
        snapshot.processCount = processes.count
        snapshot.apps = grouper.group(processes)
        snapshot.projects = projectDetector.projects(from: processes, now: snapshot.date)
        #if DEBUG
        // Screenshot mode: `-debug.machineName "MacBook Pro"` and `-debug.projectsRoot ~/Demo` keep
        // personal names and project folders out of published images.
        if let name = UserDefaults.standard.string(forKey: "debug.machineName") { snapshot.machineName = name }
        if let root = UserDefaults.standard.string(forKey: "debug.projectsRoot") {
            let prefix = (root as NSString).expandingTildeInPath + "/"
            snapshot.projects = snapshot.projects.filter { $0.path.hasPrefix(prefix) }
        }
        #endif

        HistoryStore.shared.record(snapshot)
        AlertEngine.shared.evaluate(snapshot)

        DispatchQueue.main.async { [weak self] in
            self?.publish(snapshot)
        }
    }

    private func publish(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        recent.append(snapshot)
        hasSample = true
        for observer in observers.values { observer(snapshot) }
    }

    /// "MacBook Pro (16-inch, 2021)" on Apple silicon, the model identifier elsewhere.
    static let productName: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,
           let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
            let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            if !name.isEmpty { return name }
        }
        return Sysctl.string("hw.model") ?? "Mac"
    }()
}
