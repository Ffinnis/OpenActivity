//
//  CPUSampler.swift
//  OpenActivity
//
//  System-wide CPU load from the per-core tick counters.
//

import Darwin
import Foundation

final class CPUSampler {
    private var previousTicks: [[UInt32]] = []
    private let staticInfo: CPUStats

    init() {
        var info = CPUStats()
        info.modelName = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
        info.logicalCores = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let levels = Sysctl.int("hw.nperflevels") ?? 1
        if levels > 1 {
            info.performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
            info.efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        } else {
            info.performanceCores = info.logicalCores
        }
        staticInfo = info
    }

    func sample() -> CPUStats {
        var stats = staticInfo
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { stats.loadAverage = loads }

        let ticks = Self.coreTicks()
        guard ticks.count == previousTicks.count else {
            previousTicks = ticks
            return stats
        }

        var user = 0.0, system = 0.0, total = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(ticks.count)
        for (now, before) in zip(ticks, previousTicks) {
            // Counters are 32-bit and wrap; unsigned subtraction handles that.
            let dUser = Double(now[Int(CPU_STATE_USER)] &- before[Int(CPU_STATE_USER)])
                + Double(now[Int(CPU_STATE_NICE)] &- before[Int(CPU_STATE_NICE)])
            let dSystem = Double(now[Int(CPU_STATE_SYSTEM)] &- before[Int(CPU_STATE_SYSTEM)])
            let dIdle = Double(now[Int(CPU_STATE_IDLE)] &- before[Int(CPU_STATE_IDLE)])
            let coreTotal = dUser + dSystem + dIdle
            user += dUser
            system += dSystem
            total += coreTotal
            perCore.append(coreTotal > 0 ? (dUser + dSystem) / coreTotal : 0)
        }
        previousTicks = ticks
        if total > 0 {
            stats.user = user / total
            stats.system = system / total
        }
        stats.perCore = perCore
        return stats
    }

    private static func coreTicks() -> [[UInt32]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(HostPort.shared, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
        }
    }
}

/// `mach_host_self()` adds a send-right reference on every call; take one and keep it.
enum HostPort {
    static let shared = mach_host_self()
}

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit; the unused upper bytes stay zero.
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
