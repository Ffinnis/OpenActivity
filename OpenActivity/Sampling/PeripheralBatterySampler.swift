//
//  PeripheralBatterySampler.swift
//  OpenActivity
//
//  Battery levels of connected peripherals. Apple mice, keyboards and trackpads publish
//  "BatteryPercent" in the IORegistry, read on every sample. AirPods, Beats and other
//  Bluetooth audio only show up in `system_profiler SPBluetoothDataType`, which is slow, so it
//  runs in the background at most every two minutes and sample() returns the cached result.
//

import Foundation
import IOKit

final class PeripheralBatterySampler {
    private static let bluetoothRefreshInterval: TimeInterval = 120
    private static let systemProfilerTimeout: TimeInterval = 30

    private struct BluetoothDevice {
        var name: String
        var address: String
        var minorType: String?
        var batteries: [PeripheralBattery]
    }

    private let queue = DispatchQueue(label: "OpenActivity.PeripheralBatterySampler", qos: .utility)
    private let lock = NSLock()
    private var bluetoothDevices: [BluetoothDevice] = []
    private var lastRefresh: TimeInterval = -.infinity
    private var isRefreshing = false

    init() {
        refreshBluetoothIfNeeded()
    }

    /// Never blocks on system_profiler.
    func sample() -> [PeripheralBattery] {
        refreshBluetoothIfNeeded()
        let bluetooth = lock.withLock { bluetoothDevices }
        let namesByAddress = Dictionary(bluetooth.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [PeripheralBattery] = []
        var seenAddresses = Set<String>()
        for device in registryDevices() {
            if let address = device.address {
                guard seenAddresses.insert(address).inserted else { continue }
            }
            let known = device.address.flatMap { namesByAddress[$0] }
            let name = device.name ?? known?.name ?? "Bluetooth Device"
            let kind = Self.kind(name: name, minorType: known?.minorType ?? device.usageKind)
            result.append(PeripheralBattery(name: name, kind: kind, charge: device.charge, isCharging: device.isCharging))
        }
        for device in bluetooth where !seenAddresses.contains(device.address) {
            result += device.batteries
        }
        return result
    }

    // MARK: - IORegistry

    private struct RegistryDevice {
        var name: String?
        var address: String?
        var charge: Double
        var isCharging: Bool
        var usageKind: String?
    }

    private func registryDevices() -> [RegistryDevice] {
        let matching = IOServiceMatching("IOService") as NSMutableDictionary
        matching["IOPropertyExistsMatch"] = "BatteryPercent"
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [RegistryDevice] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let percent = (properties["BatteryPercent"] as? NSNumber)?.doubleValue,
                  percent >= 0, percent <= 100
            else { continue }

            let product = (properties["Product"] as? String)?.trimmingCharacters(in: .whitespaces)
            let address = (properties["DeviceAddress"] as? String) ?? (properties["SerialNumber"] as? String)
            // BatteryStatusFlags is undocumented; the low bits are set while the device charges.
            let flags = (properties["BatteryStatusFlags"] as? NSNumber)?.intValue ?? 0
            devices.append(RegistryDevice(
                name: product?.isEmpty == false ? product : nil,
                address: address.flatMap(Self.normalizedAddress),
                charge: percent / 100,
                isCharging: flags & 0x3 != 0,
                usageKind: Self.usageKind(properties["DeviceUsagePairs"])))
        }
        return devices
    }

    /// Mouse, keyboard or trackpad from the HID usages the device advertises.
    private static func usageKind(_ pairs: Any?) -> String? {
        guard let pairs = pairs as? [[String: Any]] else { return nil }
        let usages = pairs.compactMap { pair -> (Int, Int)? in
            guard let page = (pair["DeviceUsagePage"] as? NSNumber)?.intValue,
                  let usage = (pair["DeviceUsage"] as? NSNumber)?.intValue else { return nil }
            return (page, usage)
        }
        if usages.contains(where: { $0 == (0x0D, 0x05) }) { return "Trackpad" }
        if usages.contains(where: { $0 == (0x01, 0x06) }) { return "Keyboard" }
        if usages.contains(where: { $0 == (0x01, 0x02) }) { return "Mouse" }
        return nil
    }

    // MARK: - system_profiler

    private func refreshBluetoothIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldRun = lock.withLock { () -> Bool in
            guard !isRefreshing, now - lastRefresh >= Self.bluetoothRefreshInterval else { return false }
            isRefreshing = true
            lastRefresh = now
            return true
        }
        guard shouldRun else { return }
        queue.async { [weak self] in
            let devices = Self.runSystemProfiler()
            guard let self else { return }
            self.lock.withLock {
                if let devices { self.bluetoothDevices = devices }
                self.isRefreshing = false
            }
        }
    }

    /// nil when system_profiler failed (keeps the previous result).
    private static func runSystemProfiler() -> [BluetoothDevice]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + systemProfilerTimeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }
        return controllers.flatMap { controller -> [BluetoothDevice] in
            let connected = controller["device_connected"] as? [[String: Any]] ?? []
            return connected.flatMap { entry in
                entry.compactMap { name, info in (info as? [String: Any]).flatMap { parseDevice(name: name, info: $0) } }
            }
        }
    }

    private static func parseDevice(name: String, info: [String: Any]) -> BluetoothDevice? {
        guard let address = (info["device_address"] as? String).flatMap(normalizedAddress) else { return nil }
        let minorType = info["device_minorType"] as? String
        let kind = kind(name: name, minorType: minorType)
        func level(_ key: String) -> Double? {
            guard let text = info[key] as? String,
                  let value = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))),
                  value >= 0, value <= 100 else { return nil }
            return value / 100
        }

        var batteries: [PeripheralBattery] = []
        let buds = [level("device_batteryLevelLeft"), level("device_batteryLevelRight")].compactMap { $0 }
        if let lowest = buds.min() {
            batteries.append(PeripheralBattery(name: name, kind: kind, charge: lowest, isCharging: false))
        } else if let main = level("device_batteryLevelMain") ?? level("device_batteryLevel") {
            batteries.append(PeripheralBattery(name: name, kind: kind, charge: main, isCharging: false))
        }
        if let caseLevel = level("device_batteryLevelCase") {
            batteries.append(PeripheralBattery(name: "\(name) Case", kind: kind, charge: caseLevel, isCharging: false))
        }
        return BluetoothDevice(name: name, address: address, minorType: minorType, batteries: batteries)
    }

    // MARK: - Helpers

    /// "20-91-df-4f-89-40" and "20:91:DF:4F:89:40" both become "20:91:df:4f:89:40".
    private static func normalizedAddress(_ raw: String) -> String? {
        let hex = raw.lowercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
    }

    private static func kind(name: String, minorType: String?) -> String {
        let text = "\(name) \(minorType ?? "")".lowercased()
        if text.contains("airpods") { return "AirPods" }
        if text.contains("trackpad") { return "Trackpad" }
        if text.contains("keyboard") { return "Keyboard" }
        if text.contains("mouse") { return "Mouse" }
        if ["headphone", "headset", "earbud", "beats", "buds"].contains(where: text.contains) { return "Headphones" }
        return "Other"
    }
}
