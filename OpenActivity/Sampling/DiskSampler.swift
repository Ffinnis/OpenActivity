//
//  DiskSampler.swift
//  OpenActivity
//
//  Mounted volumes and system-wide disk throughput. Volume capacities come from
//  URL resource values; byte counters from IOBlockStorageDriver statistics.
//

import Foundation
import IOKit

final class DiskSampler {
    private static let volumeRefreshInterval: TimeInterval = 30
    private static let resourceKeys: [URLResourceKey] = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeLocalizedNameKey,
        .volumeIsInternalKey,
        .volumeIsBrowsableKey,
        .volumeIsLocalKey,
    ]

    private var volumes: [VolumeInfo] = []
    private var lastVolumeRefresh: Date?
    private var lastMountCount: Int32 = -1

    /// Registry entry ID → (bytes read, bytes written) at the previous sample.
    private var previousCounters: [UInt64: (read: UInt64, write: UInt64)] = [:]
    /// Registry entry ID → whether the driver sits on a disk image or other virtual device.
    private var virtualDrivers: [UInt64: Bool] = [:]
    private var previousTime: UInt64?

    init() {}

    func sample() -> DiskStats {
        refreshVolumesIfNeeded()
        var stats = DiskStats(volumes: volumes)
        sampleIO(into: &stats)
        return stats
    }

    // MARK: - Volumes

    private func refreshVolumesIfNeeded() {
        let mountCount = getfsstat(nil, 0, MNT_NOWAIT)
        let now = Date()
        if let last = lastVolumeRefresh,
           now.timeIntervalSince(last) < Self.volumeRefreshInterval,
           mountCount == lastMountCount {
            return
        }
        lastVolumeRefresh = now
        lastMountCount = mountCount
        volumes = Self.enumerateVolumes()
    }

    private static func enumerateVolumes() -> [VolumeInfo] {
        // Resource lookups on a network share block until it answers, which can take minutes when it
        // is unreachable. The mount table (MNT_NOWAIT) never blocks, so filter to local mounts first.
        let urls = localMountPoints().map { URL(fileURLWithPath: $0, isDirectory: true) }

        var result: [VolumeInfo] = []
        for url in urls {
            let path = url.path
            let isRoot = path == "/"
            guard isRoot || path.hasPrefix("/Volumes/") else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.volumeIsLocal ?? true,
                  isRoot || values.volumeIsBrowsable ?? true,
                  let total = values.volumeTotalCapacity, total > 0
            else { continue }

            let free = values.volumeAvailableCapacityForImportantUsage.map { max(0, $0) }
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            result.append(VolumeInfo(
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                path: path,
                total: UInt64(total),
                free: UInt64(max(0, min(free, Int64(total)))),
                isInternal: values.volumeIsInternal ?? isRoot,
                isRoot: isRoot
            ))
        }
        return result.sorted {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// "/" and the visible local volumes under /Volumes, from the kernel's mount table.
    private static func localMountPoints() -> [String] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return ["/"] }
        var mounts = Array(repeating: statfs(), count: Int(count) + 4)
        let filled = getfsstat(&mounts, Int32(mounts.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else { return ["/"] }
        var paths: [String] = []
        for var mount in mounts.prefix(Int(filled)) {
            let flags = Int32(bitPattern: mount.f_flags)
            guard flags & MNT_LOCAL != 0 else { continue }
            let path = withUnsafeBytes(of: &mount.f_mntonname) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if path == "/" || (path.hasPrefix("/Volumes/") && flags & MNT_DONTBROWSE == 0) {
                paths.append(path)
            }
        }
        return paths.isEmpty ? ["/"] : paths
    }

    // MARK: - Throughput

    private func sampleIO(into stats: inout DiskStats) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        let now = DispatchTime.now().uptimeNanoseconds
        var current: [UInt64: (read: UInt64, write: UInt64)] = [:]
        var readDelta: UInt64 = 0
        var writeDelta: UInt64 = 0

        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(driver, &entryID)

            if virtualDrivers[entryID] == nil {
                virtualDrivers[entryID] = Self.isVirtual(driver: driver)
            }
            if virtualDrivers[entryID] == true { continue }

            guard let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let write = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            current[entryID] = (read, write)
            stats.totalRead &+= read
            stats.totalWritten &+= write

            if let previous = previousCounters[entryID] {
                readDelta &+= read > previous.read ? read - previous.read : 0
                writeDelta &+= write > previous.write ? write - previous.write : 0
            }
        }

        if let previousTime, now > previousTime {
            let seconds = Double(now - previousTime) / 1_000_000_000
            stats.readRate = Double(readDelta) / seconds
            stats.writeRate = Double(writeDelta) / seconds
        }
        previousCounters = current
        previousTime = now
        if virtualDrivers.count > current.count + 32 {
            virtualDrivers = virtualDrivers.filter { current[$0.key] != nil }
        }
    }

    /// Disk images report I/O that already shows up on the physical disk holding the image file.
    private static func isVirtual(driver: io_registry_entry_t) -> Bool {
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(device) }
        guard let characteristics = IORegistryEntryCreateCFProperty(device, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return false }
        return characteristics["Physical Interconnect"] as? String == "Virtual Interface"
            || characteristics["Physical Interconnect Location"] as? String == "File"
    }
}
