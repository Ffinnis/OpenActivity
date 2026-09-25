//
//  SensorSampler.swift
//  OpenActivity
//
//  Temperatures and fan speeds. Reads the HID thermal sensors (Apple silicon) and the SMC
//  (every Mac). Not thread-safe: call sample() from one serial queue.
//
//  On Apple silicon the CPU/GPU figures come from the HID "MTR" die sensors where they exist
//  (M1), otherwise from the SMC Tp*/Te*/Tg* die keys (M1 Pro/Max and later). The HID
//  "PMU tdie" sensors are only used for the CPU as a last resort: they belong to the power
//  management IC and do not follow CPU load.
//

import Foundation
import IOKit

final class SensorSampler {
    private let isAppleSilicon: Bool
    private let smc: SMCConnection?
    private let hid = HIDThermalSensors()

    /// Apple silicon SMC die keys, found once by enumerating the SMC.
    private var smcCPUKeys: [SMCKey] = []
    private var smcGPUKeys: [SMCKey] = []
    private var smcBatteryKeys: [SMCKey] = []
    /// Intel SMC sensors that exist on this Mac.
    private var intelGroups: [(group: IntelSensorGroup, keys: [SMCKey])] = []

    private var fans: [FanInfo] = []
    private var fanLimitsRefreshed = Date.distantPast

    init() {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        isAppleSilicon = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        smc = SMCConnection()
        if let smc {
            if isAppleSilicon {
                discoverAppleSiliconKeys(smc)
            } else {
                intelGroups = IntelSensorGroup.all.compactMap { group in
                    let keys = group.keys.map(SMCKey.init).filter { smc.info(for: $0) != nil }
                    return keys.isEmpty ? nil : (group, keys)
                }
            }
            discoverFans(smc)
        }
    }

    func sample() -> SensorStats {
        var stats = SensorStats()
        var cpuValues: [Double] = []
        var gpuValues: [Double] = []

        let hidGroups = hid.read()
        let hidCPU = hidGroups.filter { $0.role == .cpu }
        let hidGPU = hidGroups.filter { $0.role == .gpu }

        func add(_ name: String, _ kind: SensorKind, _ values: [Double]) {
            guard !values.isEmpty else { return }
            stats.temperatures.append(TemperatureReading(name: name, kind: kind, celsius: values.average))
        }

        // CPU
        if !hidCPU.isEmpty {
            for group in hidCPU {
                add(group.name, .cpu, group.values)
                if group.name != "SoC" { cpuValues += group.values }
            }
            if cpuValues.isEmpty { cpuValues = hidCPU.flatMap(\.values) }
        } else if let smc, !smcCPUKeys.isEmpty {
            cpuValues = smcCPUKeys.compactMap { smc.readTemperature($0) }
            add("CPU Cores", .cpu, cpuValues)
            if let hottest = cpuValues.max(), cpuValues.count > 1 {
                stats.temperatures.append(TemperatureReading(name: "CPU Hotspot", kind: .cpu, celsius: hottest))
            }
        }

        // GPU
        if !hidGPU.isEmpty {
            for group in hidGPU {
                add(group.name, .gpu, group.values)
                gpuValues += group.values
            }
        } else if let smc, !smcGPUKeys.isEmpty {
            gpuValues = smcGPUKeys.compactMap { smc.readTemperature($0) }
            add("GPU", .gpu, gpuValues)
            if let hottest = gpuValues.max(), gpuValues.count > 1 {
                stats.temperatures.append(TemperatureReading(name: "GPU Hotspot", kind: .gpu, celsius: hottest))
            }
        }

        // Intel SMC
        for (group, keys) in intelGroups {
            guard let smc else { break }
            let values = keys.compactMap { smc.readTemperature($0) }
            add(group.name, group.kind, values)
            if group.isCPUDie { cpuValues += values }
            if group.kind == .gpu { gpuValues += values }
        }
        if cpuValues.isEmpty, let proximity = stats.temperatures.first(where: { $0.kind == .cpu }) {
            cpuValues = [proximity.celsius]
        }

        // Everything else HID knows about.
        for group in hidGroups {
            switch group.role {
            case .cpu, .gpu:
                continue
            case .pmu:
                if cpuValues.isEmpty {
                    add("CPU", .cpu, group.values)
                    cpuValues = group.values
                } else {
                    add(group.name, .other, group.values)
                }
            case .reading(let kind):
                add(group.name, kind, group.values)
            }
        }

        if let smc, !stats.temperatures.contains(where: { $0.kind == .battery }) {
            add("Battery", .battery, smcBatteryKeys.compactMap { smc.readTemperature($0) })
        }

        stats.temperatures.sort { $0.kind.order < $1.kind.order }
        stats.cpuTemperature = cpuValues.isEmpty ? nil : cpuValues.average
        stats.gpuTemperature = gpuValues.isEmpty ? nil : gpuValues.average
        stats.fans = readFans()
        return stats
    }

    // MARK: - SMC discovery

    private func discoverAppleSiliconKeys(_ smc: SMCConnection) {
        for key in smc.keys(withPrefix: "T") {
            let name = key.name
            let isCPU = name.hasPrefix("Tp") || name.hasPrefix("Te")
            let isGPU = name.hasPrefix("Tg")
            let isBattery = ["TB0T", "TB1T", "TB2T"].contains(name)
            guard isCPU || isGPU || isBattery,
                  smc.info(for: key)?.type == SMCConnection.DataType.float,
                  smc.readTemperature(key) != nil  // drops sensors that read 0 (absent on this model)
            else { continue }
            if isCPU { smcCPUKeys.append(key) }
            else if isGPU { smcGPUKeys.append(key) }
            else { smcBatteryKeys.append(key) }
        }
    }

    // MARK: - Fans

    private struct FanInfo {
        var index: Int
        var name: String
        var minRPM: Double
        var maxRPM: Double
    }

    private func discoverFans(_ smc: SMCConnection) {
        let count = Int(smc.readNumber(SMCKey("FNum")) ?? 0)
        guard count > 0 else { return }
        fans = (0..<min(count, 8)).map { index in
            var name = count == 1 ? "Fan" : count == 2 ? (index == 0 ? "Left Fan" : "Right Fan") : "Fan \(index + 1)"
            // Intel Macs describe their fans in F<i>ID: 4 bytes of type/zone/location, then an ASCII name.
            if let bytes = smc.readBytes(SMCKey("F\(index)ID")), bytes.count > 4,
               let label = String(bytes: bytes[4...].prefix { $0 != 0 }, encoding: .ascii)?
                   .trimmingCharacters(in: .whitespaces), !label.isEmpty {
                name = label.localizedCaseInsensitiveContains("fan") ? label : "\(label) Fan"
            }
            return FanInfo(index: index, name: name, minRPM: 0, maxRPM: 0)
        }
    }

    private func readFans() -> [FanReading] {
        guard let smc, !fans.isEmpty else { return [] }
        if Date().timeIntervalSince(fanLimitsRefreshed) > 60 {
            fanLimitsRefreshed = Date()
            for i in fans.indices {
                fans[i].minRPM = smc.readNumber(SMCKey("F\(fans[i].index)Mn")) ?? 0
                fans[i].maxRPM = smc.readNumber(SMCKey("F\(fans[i].index)Mx")) ?? 0
            }
        }
        return fans.compactMap { fan in
            guard let rpm = smc.readNumber(SMCKey("F\(fan.index)Ac")), rpm.isFinite, rpm >= 0, rpm < 20_000 else { return nil }
            return FanReading(name: fan.name, rpm: rpm, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
        }
    }
}

// MARK: - Helpers

private extension Array where Element == Double {
    var average: Double { isEmpty ? 0 : reduce(0, +) / Double(count) }
}

private extension SensorKind {
    var order: Int {
        switch self {
        case .cpu: return 0
        case .gpu: return 1
        case .memory: return 2
        case .storage: return 3
        case .battery: return 4
        case .ambient: return 5
        case .other: return 6
        }
    }
}

private func isPlausibleTemperature(_ value: Double) -> Bool {
    value.isFinite && value > 0 && value <= 130
}

private struct IntelSensorGroup {
    var name: String
    var kind: SensorKind
    var keys: [String]
    /// Counts toward cpuTemperature.
    var isCPUDie = false

    static let all: [IntelSensorGroup] = [
        .init(name: "CPU Die", kind: .cpu, keys: ["TC0D", "TC0E", "TC0F", "TCXC"], isCPUDie: true),
        .init(name: "CPU Cores", kind: .cpu, keys: (1...9).map { "TC\($0)C" }, isCPUDie: true),
        .init(name: "CPU Proximity", kind: .cpu, keys: ["TC0P"]),
        .init(name: "CPU Heatsink", kind: .cpu, keys: ["TC0H"]),
        .init(name: "GPU Die", kind: .gpu, keys: ["TG0D", "TCGC"]),
        .init(name: "GPU Proximity", kind: .gpu, keys: ["TG0P"]),
        .init(name: "Memory", kind: .memory, keys: ["TM0P", "Tm0P"]),
        .init(name: "SSD", kind: .storage, keys: ["TH0a", "TH0b", "TH0P"]),
        .init(name: "Battery", kind: .battery, keys: ["TB0T", "TB1T", "TB2T"]),
        .init(name: "Ambient", kind: .ambient, keys: ["TA0P", "TA0V", "TA1P"]),
        .init(name: "Platform Controller Hub", kind: .other, keys: ["TPCD"]),
        .init(name: "Wi-Fi", kind: .other, keys: ["TW0P"]),
    ]
}

// MARK: - HID thermal sensors (private IOHIDEventSystemClient API)

private final class HIDThermalSensors {
    enum Role: Equatable {
        case cpu, gpu
        /// Power-management IC die: a CPU stand-in only when nothing better exists.
        case pmu
        case reading(SensorKind)
    }

    struct Group {
        var name: String
        var role: Role
        var values: [Double]
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValueFn = @convention(c) (CFTypeRef, UInt32) -> Double

    private struct API {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let getFloatValue: GetFloatValueFn

        static let shared: API? = {
            guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
            func load<T>(_ name: String, as _: T.Type) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let create = load("IOHIDEventSystemClientCreate", as: CreateFn.self),
                  let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
                  let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
                  let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
                  let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
                  let getFloatValue = load("IOHIDEventGetFloatValue", as: GetFloatValueFn.self)
            else { return nil }
            return API(create: create, setMatching: setMatching, copyServices: copyServices,
                       copyProperty: copyProperty, copyEvent: copyEvent, getFloatValue: getFloatValue)
        }()
    }

    private static let temperatureEventType: Int64 = 15  // kIOHIDEventTypeTemperature
    private static let temperatureField = UInt32(15 << 16)  // kIOHIDEventFieldTemperatureLevel

    private let api = API.shared
    private let client: CFTypeRef?
    /// Services we read, with the group each one belongs to.
    private var services: [(service: CFTypeRef, name: String, role: Role)] = []
    private var servicesRefreshed = Date.distantPast

    init() {
        guard let api, let client = api.create(kCFAllocatorDefault)?.takeRetainedValue() else {
            client = nil
            return
        }
        api.setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
    }

    /// Current readings, averaged per friendly name, in first-seen order.
    func read() -> [Group] {
        guard let api, client != nil else { return [] }
        if services.isEmpty || Date().timeIntervalSince(servicesRefreshed) > 300 {
            refreshServices(api)
        }
        var groups: [Group] = []
        var index: [String: Int] = [:]
        for entry in services {
            guard let event = api.copyEvent(entry.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let value = api.getFloatValue(event, Self.temperatureField)
            guard isPlausibleTemperature(value) else { continue }
            if let i = index[entry.name] {
                groups[i].values.append(value)
            } else {
                index[entry.name] = groups.count
                groups.append(Group(name: entry.name, role: entry.role, values: [value]))
            }
        }
        return groups
    }

    private func refreshServices(_ api: API) {
        servicesRefreshed = Date()
        guard let client, let list = api.copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return }
        // Each event read costs about a millisecond, so near-duplicate sensors (six battery
        // gauges, twenty-odd PMU dies) are sampled rather than all read. CPU/GPU die sensors
        // are distinct cores and are all kept.
        var perName: [String: Int] = [:]
        services = list.compactMap { service in
            guard let product = api.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let (name, role) = Self.classify(product)
            else { return nil }
            let limit: Int
            switch role {
            case .cpu, .gpu: limit = .max
            case .pmu: limit = 2
            case .reading: limit = 2
            }
            perName[name, default: 0] += 1
            return perName[name]! <= limit ? (service, name, role) : nil
        }
    }

    /// Friendly name and role for a raw HID sensor name, or nil to skip it.
    static func classify(_ product: String) -> (String, Role)? {
        let p = product.trimmingCharacters(in: .whitespaces)
        func has(_ prefix: String) -> Bool { p.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil }
        if has("pACC MTR Temp") { return ("CPU Performance Cores", .cpu) }
        if has("eACC MTR Temp") { return ("CPU Efficiency Cores", .cpu) }
        if has("SOC MTR Temp") { return ("SoC", .cpu) }
        if has("GPU MTR Temp") { return ("GPU", .gpu) }
        if has("ANE MTR Temp") { return ("Neural Engine", .reading(.other)) }
        if has("ISP MTR Temp") { return ("Image Signal Processor", .reading(.other)) }
        if has("PMGR SOC Die Temp") { return ("SoC Power Manager", .reading(.other)) }
        if has("PMU tdie") || has("PMU2 tdie") { return ("Power Management IC", .pmu) }
        // Raw PMIC thermistors (tdev, tcal, TP*): dozens of unlabeled duplicates.
        if has("PMU") { return nil }
        if has("NAND") { return ("SSD", .reading(.storage)) }
        if has("gas gauge battery") || has("Battery") { return ("Battery", .reading(.battery)) }
        // Unknown sensor: strip "Temp", "Sensor", "MTR" and trailing indices so duplicates collapse.
        let words = p.split(separator: " ").filter { word in
            let w = word.lowercased()
            return !["temp", "sensor", "mtr", "temperature"].contains(w) && Int(w) == nil
        }
        var name = words.joined(separator: " ")
        while let last = name.last, last.isNumber { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (name, .reading(.other))
    }
}

// MARK: - SMC

/// A four-character SMC key such as "TC0P".
private struct SMCKey: Hashable {
    let code: UInt32

    init(_ name: String) {
        code = name.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    init(code: UInt32) { self.code = code }

    var name: String { fourCharString(code) }
}

private func fourCharString(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Mirrors the C `SMCKeyData_t` used by the AppleSMC user client (80 bytes).
private struct SMCParam {
    var key: UInt32 = 0
    var versMajor: UInt8 = 0, versMinor: UInt8 = 0, versBuild: UInt8 = 0, versReserved: UInt8 = 0
    var versRelease: UInt16 = 0
    private var padding0: UInt16 = 0
    var pLimitVersion: UInt16 = 0, pLimitLength: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    private var padding1: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    private var padding2: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private final class SMCConnection {
    enum DataType {
        static let float = SMCKey("flt ").code
        static let sp78 = SMCKey("sp78").code
        static let fpe2 = SMCKey("fpe2").code
        static let ui8 = SMCKey("ui8 ").code
        static let ui16 = SMCKey("ui16").code
        static let ui32 = SMCKey("ui32").code
    }

    struct KeyInfo {
        var size: UInt32
        var type: UInt32
    }

    private enum Command: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    private static let kernelIndex: UInt32 = 2  // kSMCHandleYPCEvent
    private var connection: io_connect_t = 0
    /// nil means the key does not exist.
    private var infoCache: [UInt32: KeyInfo?] = [:]

    init?() {
        assert(MemoryLayout<SMCParam>.size == 80)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.stride
        let status = IOConnectCallStructMethod(connection, Self.kernelIndex,
                                               &input, MemoryLayout<SMCParam>.stride,
                                               &output, &outputSize)
        guard status == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    func info(for key: SMCKey) -> KeyInfo? {
        if let cached = infoCache[key.code] { return cached }
        var input = SMCParam()
        input.key = key.code
        input.command = Command.readKeyInfo.rawValue
        let info = call(&input).map { KeyInfo(size: $0.dataSize, type: $0.dataType) }
        infoCache[key.code] = .some(info)
        return info
    }

    func readBytes(_ key: SMCKey) -> [UInt8]? {
        guard let info = info(for: key), info.size > 0, info.size <= 32 else { return nil }
        var input = SMCParam()
        input.key = key.code
        input.dataSize = info.size
        input.command = Command.readBytes.rawValue
        guard var output = call(&input) else { return nil }
        return withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.size))) }
    }

    /// Decodes numeric keys (flt, sp78, fpe2, ui8, ui16, ui32).
    func readNumber(_ key: SMCKey) -> Double? {
        guard let type = info(for: key)?.type, let b = readBytes(key) else { return nil }
        switch type {
        case DataType.float where b.count == 4:
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case DataType.sp78 where b.count == 2:
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case DataType.fpe2 where b.count == 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case DataType.ui8 where b.count == 1:
            return Double(b[0])
        case DataType.ui16 where b.count == 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case DataType.ui32 where b.count == 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }

    func readTemperature(_ key: SMCKey) -> Double? {
        readNumber(key).flatMap { isPlausibleTemperature($0) ? $0 : nil }
    }

    private var keyCount: Int {
        Int(readNumber(SMCKey("#KEY")) ?? 0)
    }

    private func key(at index: Int) -> SMCKey? {
        var input = SMCParam()
        input.command = Command.readIndex.rawValue
        input.data32 = UInt32(index)
        return call(&input).map { SMCKey(code: $0.key) }
    }

    /// All keys starting with `prefix` (one character). The SMC lists keys sorted, so a binary
    /// search finds the range; falls back to a full scan if the order looks wrong.
    func keys(withPrefix prefix: Character) -> [SMCKey] {
        let count = keyCount
        guard count > 0, let ascii = prefix.asciiValue else { return [] }
        let lower = UInt32(ascii) << 24, upper = UInt32(ascii + 1) << 24

        func firstIndex(atLeast code: UInt32) -> Int {
            var low = 0, high = count
            while low < high {
                let mid = (low + high) / 2
                if let key = key(at: mid), key.code < code { low = mid + 1 } else { high = mid }
            }
            return low
        }

        let start = firstIndex(atLeast: lower), end = firstIndex(atLeast: upper)
        let ranged = (start..<max(start, end)).compactMap { key(at: $0) }
        if !ranged.isEmpty, ranged.allSatisfy({ $0.code >= lower && $0.code < upper }) {
            return ranged
        }
        return (0..<count).compactMap { key(at: $0) }.filter { $0.code >= lower && $0.code < upper }
    }
}
