//
//  GPUSampler.swift
//  OpenActivity
//
//  GPU utilization and memory from the IOAccelerator's PerformanceStatistics,
//  and per-process GPU time from the accelerator's user clients.
//

import Foundation
import IOKit

final class GPUSampler {
    private struct Client {
        let pid: Int32
        var gpuTime: UInt64
    }

    private struct Identity {
        var name: String
        var coreCount: Int?
    }

    /// User client registry entry ID → owner and accumulated GPU time at the previous sample.
    private var previousClients: [UInt64: Client] = [:]
    /// Accelerator registry entry ID → static name and core count.
    private var identities: [UInt64: Identity] = [:]
    /// User client registry entry ID → owning pid (nil when the client has no creator we can parse).
    private var clientOwners: [UInt64: Int32?] = [:]
    private var previousTime: UInt64?

    init() {}

    func sample() -> (stats: GPUStats, perProcess: [Int32: Double]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return (GPUStats(), [:])
        }
        defer { IOObjectRelease(iterator) }

        let now = DispatchTime.now().uptimeNanoseconds
        var best: GPUStats?
        var clients: [UInt64: Client] = [:]

        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            let stats = systemStats(of: accelerator)
            if best == nil || stats.utilization > best!.utilization { best = stats }
            collectClients(of: accelerator, into: &clients)
        }

        var perProcess: [Int32: Double] = [:]
        if let previousTime, now > previousTime {
            let elapsed = Double(now - previousTime)
            var busy: [Int32: UInt64] = [:]
            for (id, client) in clients {
                // A client that appeared since the last sample did all its work within the interval.
                let before = previousClients[id]?.gpuTime ?? 0
                if client.gpuTime > before { busy[client.pid, default: 0] += client.gpuTime - before }
            }
            for (pid, time) in busy {
                perProcess[pid] = min(100, Double(time) / elapsed * 100)
            }
        }

        previousClients = clients
        previousTime = now
        if clientOwners.count > clients.count * 2 + 64 {
            clientOwners = clientOwners.filter { clients[$0.key] != nil }
        }
        return (best ?? GPUStats(), perProcess)
    }

    // MARK: - System

    private func systemStats(of accelerator: io_registry_entry_t) -> GPUStats {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(accelerator, &entryID)
        let identity = identities[entryID] ?? {
            let identity = Self.identity(of: accelerator)
            identities[entryID] = identity
            return identity
        }()

        var stats = GPUStats(name: identity.name, coreCount: identity.coreCount)
        if let performance = Self.property("PerformanceStatistics", of: accelerator) as? [String: Any] {
            let utilization = (performance["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0
            stats.utilization = min(1, max(0, utilization / 100))
            let memory = performance["In use system memory"] as? NSNumber
                ?? performance["vramUsedBytes"] as? NSNumber
            stats.memoryInUse = memory?.uint64Value ?? 0
        }
        return stats
    }

    private static func identity(of accelerator: io_registry_entry_t) -> Identity {
        var name: String?
        switch property("model", of: accelerator) {
        case let string as String: name = string
        case let data as Data: name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        default: break
        }
        if name?.isEmpty ?? true {
            var buffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
            if IORegistryEntryGetName(accelerator, &buffer) == KERN_SUCCESS {
                name = String(cString: buffer)
            }
        }
        let cores = (property("gpu-core-count", of: accelerator) as? NSNumber)?.intValue
        return Identity(name: name ?? "GPU", coreCount: cores)
    }

    // MARK: - Per process

    private func collectClients(of accelerator: io_registry_entry_t, into clients: inout [UInt64: Client]) {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(children) }

        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(child, &entryID)

            let owner: Int32?
            if let cached = clientOwners[entryID] {
                owner = cached
            } else {
                owner = (Self.property("IOUserClientCreator", of: child) as? String).flatMap(Self.pid(fromCreator:))
                clientOwners[entryID] = owner
            }
            guard let pid = owner,
                  let usage = Self.property("AppUsage", of: child) as? [[String: Any]], !usage.isEmpty
            else { continue }

            let gpuTime = usage.reduce(UInt64(0)) { $0 &+ ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
            clients[entryID] = Client(pid: pid, gpuTime: gpuTime)
        }
    }

    /// Parses "pid 392, WindowServer".
    private static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
