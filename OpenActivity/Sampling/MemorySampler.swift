//
//  MemorySampler.swift
//  OpenActivity
//
//  Memory split the way Activity Monitor splits it: app, wired, compressed, cached, free.
//

import Darwin
import Foundation

final class MemorySampler {
    private let total = UInt64(ProcessInfo.processInfo.physicalMemory)
    private let pageSize = UInt64(vm_kernel_page_size)

    func sample() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = total

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(HostPort.shared, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            stats.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            stats.wired = UInt64(vm.wire_count) * pageSize
            stats.compressed = UInt64(vm.compressor_page_count) * pageSize
            stats.cached = (UInt64(vm.external_page_count) + purgeable) * pageSize
            let accounted = stats.used + stats.cached
            stats.free = total > accounted ? total - accounted : 0
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            stats.swapUsed = swap.xsu_used
            stats.swapTotal = swap.xsu_total
        }

        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level") {
            stats.pressure = MemoryPressure(rawValue: level) ?? .normal
        }
        return stats
    }
}
