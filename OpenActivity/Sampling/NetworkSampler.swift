//
//  NetworkSampler.swift
//  OpenActivity
//
//  System-wide network throughput from the 64-bit interface MIB counters,
//  plus the primary interface as reported by SystemConfiguration.
//

import Foundation
import SystemConfiguration

final class NetworkSampler {
    private static let primaryRefreshInterval: TimeInterval = 10

    /// Interface index and BSD name of every physical interface.
    private var interfaces: [(index: Int32, name: String)] = []
    private var lastInterfaceRefresh = Date.distantPast
    private var previousCounters: [String: (in: UInt64, out: UInt64)] = [:]
    private var previousTime: UInt64?

    private let store = SCDynamicStoreCreate(nil, "OpenActivity.NetworkSampler" as CFString, nil, nil)
    private var lastPrimaryRefresh: Date?
    private var primaryName = ""
    private var primaryKind = ""
    private var primaryAddress: String?
    private var displayNames: [String: String] = [:]

    init() {}

    func sample() -> NetworkStats {
        refreshPrimaryIfNeeded()
        var stats = NetworkStats(interfaceName: primaryName, interfaceKind: primaryKind, localAddress: primaryAddress)

        let now = DispatchTime.now().uptimeNanoseconds
        let counters = readCounters()
        var inDelta: UInt64 = 0
        var outDelta: UInt64 = 0
        for (name, value) in counters {
            stats.totalIn &+= value.in
            stats.totalOut &+= value.out
            if let previous = previousCounters[name] {
                inDelta &+= value.in > previous.in ? value.in - previous.in : 0
                outDelta &+= value.out > previous.out ? value.out - previous.out : 0
            }
        }
        if let previousTime, now > previousTime {
            let seconds = Double(now - previousTime) / 1_000_000_000
            stats.inRate = Double(inDelta) / seconds
            stats.outRate = Double(outDelta) / seconds
        }
        previousCounters = counters
        previousTime = now
        return stats
    }

    // MARK: - Counters

    /// Wi-Fi, Ethernet and Thunderbolt ports are all en*. Loopback, VPN tunnels (utun), AirDrop (awdl, llw),
    /// bridges, hotspot (ap), gif, stf and anpi are left out: their traffic either never leaves the Mac
    /// or is already counted on an en* interface.
    private static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en")
    }

    /// Reads exact 64-bit byte counters through the interface MIB, as netstat does.
    /// NET_RT_IFLIST2 is avoided: on current macOS it hands unprivileged callers
    /// input counters truncated to 32 bits and rounded to the kilobyte.
    private func readCounters() -> [String: (in: UInt64, out: UInt64)] {
        if interfaces.isEmpty || Date().timeIntervalSince(lastInterfaceRefresh) >= Self.primaryRefreshInterval {
            discoverInterfaces()
        }
        var result: [String: (in: UInt64, out: UInt64)] = [:]
        for (index, name) in interfaces {
            guard let data = Self.interfaceData(index: index), Self.name(of: data) == name else {
                lastInterfaceRefresh = .distantPast
                continue
            }
            result[name] = (data.ifmd_data.ifi_ibytes, data.ifmd_data.ifi_obytes)
        }
        return result
    }

    private func discoverInterfaces() {
        lastInterfaceRefresh = Date()
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var count: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctl(&mib, UInt32(mib.count), &count, &size, nil, 0) == 0 else { return }

        interfaces = (1...max(1, Int32(count))).compactMap { index in
            guard let data = Self.interfaceData(index: index) else { return nil }
            let name = Self.name(of: data)
            return Self.isPhysical(name) ? (index, name) : nil
        }
    }

    private static func interfaceData(index: Int32) -> ifmibdata? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0 else { return nil }
        return data
    }

    private static func name(of data: ifmibdata) -> String {
        withUnsafeBytes(of: data.ifmd_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    // MARK: - Primary interface

    private func refreshPrimaryIfNeeded() {
        let now = Date()
        if let last = lastPrimaryRefresh, now.timeIntervalSince(last) < Self.primaryRefreshInterval { return }
        lastPrimaryRefresh = now

        let name = primaryInterface() ?? ""
        primaryName = name
        primaryAddress = name.isEmpty ? nil : ipv4Address(of: name)
        primaryKind = name.isEmpty ? "" : displayName(of: name)
    }

    private func primaryInterface() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = value["PrimaryInterface"] as? String {
                return name
            }
        }
        return nil
    }

    private func ipv4Address(of name: String) -> String? {
        let key = "State:/Network/Interface/\(name)/IPv4" as CFString
        guard let value = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return nil }
        return (value["Addresses"] as? [String])?.first
    }

    private func displayName(of name: String) -> String {
        if displayNames[name] == nil {
            displayNames = [:]
            for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
                guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
                displayNames[bsdName] = display
            }
        }
        if let display = displayNames[name] { return display }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "VPN" }
        return name
    }
}
