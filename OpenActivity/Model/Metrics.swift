//
//  Metrics.swift
//  OpenActivity
//
//  Plain value types shared by the samplers, the history store and the UI.
//  Everything here is a snapshot: immutable once produced by the Monitor.
//

import Foundation

/// The pages of the app. Also used to pick which figure a list is sorted by.
enum Metric: String, CaseIterable, Codable {
    case overview, cpu, memory, disk, network, gpu, battery, sensors, sound, projects

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .gpu: return "GPU"
        case .battery: return "Energy"
        case .sensors: return "Sensors"
        case .sound: return "Sound"
        case .projects: return "Projects"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .gpu: return "cube.transparent"
        case .battery: return "bolt.fill"
        case .sensors: return "thermometer.medium"
        case .sound: return "speaker.wave.2"
        case .projects: return "hammer"
        }
    }

    /// Metrics that have a per-app figure and an app table.
    static let appMetrics: [Metric] = [.cpu, .memory, .disk, .network, .gpu, .battery]
}

// MARK: - Processes and apps

struct ProcessSample: Hashable {
    let pid: Int32
    var ppid: Int32
    /// The process macOS holds responsible for this one (e.g. Chrome for its helpers, Terminal for a shell).
    var responsiblePID: Int32
    var name: String
    var path: String?
    var uid: UInt32
    var startTime: Date?
    var threads: Int
    /// Percent of one core (150 = one and a half cores busy).
    var cpuPercent: Double
    /// Physical footprint in bytes, the figure Activity Monitor calls "Memory".
    var memory: UInt64
    var diskReadRate: Double
    var diskWriteRate: Double
    var netInRate: Double
    var netOutRate: Double
    /// Percent of the GPU (0...100).
    var gpuPercent: Double
    /// Watts.
    var power: Double
    /// Total CPU seconds used since launch.
    var cpuTime: Double
    /// False when macOS refused to report the figures (processes owned by root or another user).
    var isAccessible: Bool
    /// Current working directory, used to find the project a dev server belongs to.
    var workingDirectory: String?
    /// TCP ports this process is listening on.
    var listeningPorts: [UInt16]

    func value(for metric: Metric) -> Double {
        switch metric {
        case .cpu: return cpuPercent
        case .memory: return Double(memory)
        case .disk: return diskReadRate + diskWriteRate
        case .network: return netInRate + netOutRate
        case .gpu: return gpuPercent
        case .battery: return power
        default: return 0
        }
    }
}

struct AppGroup: Identifiable, Hashable {
    /// Bundle identifier, bundle path or executable name. Stable across launches.
    let id: String
    var name: String
    var bundlePath: String?
    var bundleIdentifier: String?
    /// Processes that belong to macOS itself rather than an app the user opened.
    var isSystem: Bool
    var processes: [ProcessSample] {
        didSet { updateTotals() }
    }

    // Totals over the processes, kept up to date because lists sort and filter on them constantly.
    private(set) var cpuPercent: Double = 0
    private(set) var memory: UInt64 = 0
    private(set) var diskReadRate: Double = 0
    private(set) var diskWriteRate: Double = 0
    private(set) var netInRate: Double = 0
    private(set) var netOutRate: Double = 0
    private(set) var gpuPercent: Double = 0
    private(set) var power: Double = 0
    var pids: [Int32] { processes.map(\.pid) }

    init(id: String, name: String, bundlePath: String?, bundleIdentifier: String?, isSystem: Bool, processes: [ProcessSample]) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.isSystem = isSystem
        self.processes = processes
        updateTotals()
    }

    private mutating func updateTotals() {
        var cpu = 0.0, disk = (read: 0.0, write: 0.0), net = (in: 0.0, out: 0.0), gpu = 0.0, power = 0.0
        var memory: UInt64 = 0
        for process in processes {
            cpu += process.cpuPercent
            memory += process.memory
            disk.read += process.diskReadRate
            disk.write += process.diskWriteRate
            net.in += process.netInRate
            net.out += process.netOutRate
            gpu += process.gpuPercent
            power += process.power
        }
        cpuPercent = cpu
        self.memory = memory
        diskReadRate = disk.read
        diskWriteRate = disk.write
        netInRate = net.in
        netOutRate = net.out
        gpuPercent = gpu
        self.power = power
    }

    func value(for metric: Metric) -> Double {
        switch metric {
        case .cpu: return cpuPercent
        case .memory: return Double(memory)
        case .disk: return diskReadRate + diskWriteRate
        case .network: return netInRate + netOutRate
        case .gpu: return gpuPercent
        case .battery: return power
        default: return 0
        }
    }
}

// MARK: - System figures

struct CPUStats: Hashable {
    /// Fractions of total capacity, 0...1.
    var user: Double = 0
    var system: Double = 0
    var total: Double { min(1, user + system) }
    /// 1, 5 and 15 minute load averages.
    var loadAverage: [Double] = [0, 0, 0]
    var logicalCores: Int = 0
    var performanceCores: Int = 0
    var efficiencyCores: Int = 0
    /// Busy fraction for every logical core, 0...1.
    var perCore: [Double] = []
    var modelName: String = ""
}

enum MemoryPressure: Int, Codable {
    case normal = 1, warning = 2, critical = 4

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

struct MemoryStats: Hashable {
    var total: UInt64 = 0
    /// App + wired + compressed, which is what "Memory Used" means in Activity Monitor.
    var used: UInt64 { app + wired + compressed }
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File cache that macOS hands back as soon as something needs it.
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct VolumeInfo: Hashable {
    var name: String
    var path: String
    var total: UInt64
    /// Free space including purgeable space macOS will clear on demand.
    var free: UInt64
    var isInternal: Bool
    var isRoot: Bool
    var used: UInt64 { total > free ? total - free : 0 }
}

struct DiskStats: Hashable {
    var volumes: [VolumeInfo] = []
    /// Bytes per second across all physical disks.
    var readRate: Double = 0
    var writeRate: Double = 0
    /// Bytes since boot.
    var totalRead: UInt64 = 0
    var totalWritten: UInt64 = 0
    var rootVolume: VolumeInfo? { volumes.first(where: \.isRoot) ?? volumes.first }
}

struct NetworkStats: Hashable {
    /// Bytes per second.
    var inRate: Double = 0
    var outRate: Double = 0
    /// BSD name of the primary interface, e.g. "en0".
    var interfaceName: String = ""
    /// Human name, e.g. "Wi-Fi" or "Ethernet".
    var interfaceKind: String = ""
    var localAddress: String?
    /// Bytes since boot across all physical interfaces.
    var totalIn: UInt64 = 0
    var totalOut: UInt64 = 0
}

struct GPUStats: Hashable {
    var name: String = ""
    /// 0...1.
    var utilization: Double = 0
    var memoryInUse: UInt64 = 0
    var coreCount: Int?
}

struct BatteryStats: Hashable {
    var isPresent: Bool = false
    /// 0...1.
    var charge: Double = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var isFullyCharged: Bool = false
    /// Seconds until empty (on battery) or full (charging). nil while macOS is still estimating.
    var timeRemaining: TimeInterval?
    var cycleCount: Int = 0
    /// Maximum capacity relative to design capacity, 0...1.
    var health: Double = 0
    /// Degrees Celsius.
    var temperature: Double?
    /// Watts flowing out of (positive) the battery or the adapter into the system.
    var systemPower: Double = 0
    var adapterWatts: Double?
    var condition: String = "Normal"
}

enum SensorKind: String, Codable, Hashable {
    case cpu, gpu, memory, battery, storage, ambient, other
}

struct TemperatureReading: Hashable {
    var name: String
    var kind: SensorKind
    /// Degrees Celsius.
    var celsius: Double
}

struct FanReading: Hashable {
    var name: String
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
}

struct SensorStats: Hashable {
    var temperatures: [TemperatureReading] = []
    var fans: [FanReading] = []
    /// Average of the CPU die sensors.
    var cpuTemperature: Double?
    var gpuTemperature: Double?
}

struct PeripheralBattery: Hashable {
    var name: String
    /// e.g. "AirPods", "Mouse", "Keyboard", "Trackpad", "Headphones", "Other".
    var kind: String
    /// 0...1.
    var charge: Double
    var isCharging: Bool
}

// MARK: - Dev servers

struct DevProcess: Hashable {
    var pid: Int32
    var name: String
    /// "node", "python", "go", "ruby", "java", "bun", "deno", "php", "rust", "dotnet", "elixir", "other".
    var runtime: String
    var ports: [UInt16]
    var memory: UInt64
    var cpuPercent: Double
    var startTime: Date?
    /// Last time the process used a meaningful amount of CPU. nil while it is working.
    var idleSince: Date?
    var commandLine: String
}

struct DevProject: Hashable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var processes: [DevProcess]
    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
    var ports: [UInt16] { processes.flatMap(\.ports).sorted() }
    var isIdle: Bool { !processes.isEmpty && processes.allSatisfy { $0.idleSince != nil } }
}

// MARK: - Snapshot

struct SystemSnapshot {
    var date: Date = Date()
    var uptime: TimeInterval = 0
    var machineName: String = ""
    var cpu = CPUStats()
    var memory = MemoryStats()
    var disk = DiskStats()
    var network = NetworkStats()
    var gpu = GPUStats()
    var battery = BatteryStats()
    var sensors = SensorStats()
    var peripherals: [PeripheralBattery] = []
    var apps: [AppGroup] = []
    var processCount: Int = 0
    var projects: [DevProject] = []

    func topApps(by metric: Metric, limit: Int = .max) -> [AppGroup] {
        Array(apps.sorted { $0.value(for: metric) > $1.value(for: metric) }.prefix(limit))
    }
}
