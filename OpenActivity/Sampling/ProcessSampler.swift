//
//  ProcessSampler.swift
//  OpenActivity
//
//  Every process on the Mac with its CPU, memory, disk and energy figures.
//  macOS only reports figures for processes the user owns; the rest are listed without them.
//

import Darwin
import Foundation

final class ProcessSampler {
    private struct Counters {
        /// Start time of the process the counters belong to, so a reused pid starts fresh.
        var start: Int
        var cpuTime: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var energy: UInt64
        var date: TimeInterval
    }

    private var previous: [Int32: Counters] = [:]
    private var names: [Int32: Identity] = [:]

    private struct Identity {
        var start: Int
        var comm: String
        var name: String
        var path: String?
        /// Whether the process could be a dev server, which decides if its ports are scanned.
        var mayServe: Bool
        var isRuntime: Bool
    }
    private var ports: [Int32: (start: Int, ports: [UInt16])] = [:]
    private var directories: [Int32: (start: Int, path: String?)] = [:]
    private var lastPortScan: TimeInterval = 0
    private let timebase: Double
    private let ownUID = getuid()

    /// How often listening ports and working directories are refreshed. Scanning file descriptors is the
    /// most expensive part of a sample, so it runs less often than the figures.
    var portScanInterval: TimeInterval = 8

    init() {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        timebase = Double(info.numer) / Double(info.denom)
    }

    func sample() -> [ProcessSample] {
        // Monotonic, so clock changes neither stall the port scan nor zero the rates.
        let now = ProcessInfo.processInfo.systemUptime
        let entries = Self.allProcesses()
        let scanPorts = now - lastPortScan >= portScanInterval
        if scanPorts {
            lastPortScan = now
            ports.removeAll(keepingCapacity: true)
        }

        var samples: [ProcessSample] = []
        samples.reserveCapacity(entries.count)
        var seen = Set<Int32>()
        seen.reserveCapacity(entries.count)

        for entry in entries {
            let pid = entry.kp_proc.p_pid
            guard pid > 0 || entry.kp_proc.p_stat != 0 else { continue }
            seen.insert(pid)
            let start = Int(entry.kp_proc.p_un.__p_starttime.tv_sec)
            let identity = identity(pid: pid, start: start, comm: entry.kp_proc.p_comm)

            var sample = ProcessSample(
                pid: pid,
                ppid: entry.kp_eproc.e_ppid,
                responsiblePID: Responsibility.responsiblePID(for: pid),
                name: identity.name,
                path: identity.path,
                uid: entry.kp_eproc.e_ucred.cr_uid,
                startTime: start > 0 ? Date(timeIntervalSince1970: TimeInterval(start)) : nil,
                threads: 0,
                cpuPercent: 0,
                memory: 0,
                diskReadRate: 0,
                diskWriteRate: 0,
                netInRate: 0,
                netOutRate: 0,
                gpuPercent: 0,
                power: 0,
                cpuTime: 0,
                isAccessible: false,
                workingDirectory: nil,
                listeningPorts: []
            )

            var usage = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            } == 0

            if ok {
                sample.isAccessible = true
                let cpuTicks = usage.ri_user_time &+ usage.ri_system_time
                sample.cpuTime = Double(cpuTicks) * timebase / 1e9
                sample.memory = usage.ri_phys_footprint
                let counters = Counters(
                    start: start,
                    cpuTime: cpuTicks,
                    diskRead: usage.ri_diskio_bytesread,
                    diskWrite: usage.ri_diskio_byteswritten,
                    energy: usage.ri_energy_nj,
                    date: now
                )
                if let before = previous[pid], before.start == start, now > before.date {
                    let elapsed = now - before.date
                    sample.cpuPercent = Double(delta(counters.cpuTime, before.cpuTime)) * timebase / 1e9 / elapsed * 100
                    sample.diskReadRate = Double(delta(counters.diskRead, before.diskRead)) / elapsed
                    sample.diskWriteRate = Double(delta(counters.diskWrite, before.diskWrite)) / elapsed
                    sample.power = Double(delta(counters.energy, before.energy)) / 1e9 / elapsed
                }
                previous[pid] = counters

                var task = proc_taskinfo()
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                    sample.threads = Int(task.pti_threadnum)
                }

                if sample.uid == ownUID, identity.mayServe {
                    if scanPorts {
                        let listening = Self.listeningPorts(pid: pid)
                        if !listening.isEmpty { ports[pid] = (start, listening) }
                        if !listening.isEmpty || identity.isRuntime {
                            directories[pid] = (start, Self.workingDirectory(pid: pid))
                        } else {
                            directories[pid] = nil
                        }
                    }
                    if let entry = ports[pid], entry.start == start { sample.listeningPorts = entry.ports }
                    if let entry = directories[pid], entry.start == start { sample.workingDirectory = entry.path }
                }
            }
            samples.append(sample)
        }

        if previous.count > seen.count + 64 || names.count > seen.count + 64 {
            previous = previous.filter { seen.contains($0.key) }
            names = names.filter { seen.contains($0.key) }
            directories = directories.filter { seen.contains($0.key) }
        }
        return samples
    }

    private func delta(_ now: UInt64, _ before: UInt64) -> UInt64 {
        now >= before ? now - before : 0
    }

    /// Name and path change when a pid is reused or the process execs another program (which keeps
    /// the pid and start time but changes p_comm), so they are cached by all three.
    private func identity(pid: Int32, start: Int, comm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> (name: String, path: String?, mayServe: Bool, isRuntime: Bool) {
        let shortName = withUnsafeBytes(of: comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if let cached = names[pid], cached.start == start, cached.comm == shortName {
            return (cached.name, cached.path, cached.mayServe, cached.isRuntime)
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : nil
        var name = shortName
        // p_comm is cut at 16 characters; the executable name is the full one.
        if let path {
            let executable = (path as NSString).lastPathComponent
            if executable.hasPrefix(name) || name.isEmpty { name = executable }
        }
        if pid == 0 { name = "kernel_task" }
        let isRuntime = DevRuntime.detect(name: name, path: path) != nil
        // App helpers and Apple's own binaries are never shown as dev servers, so their file
        // descriptors aren't worth scanning.
        let mayServe = isRuntime || !(path.map(Self.isAppOrSystemBinary) ?? true)
        names[pid] = Identity(start: start, comm: shortName, name: name, path: path, mayServe: mayServe, isRuntime: isRuntime)
        return (name, path, mayServe, isRuntime)
    }

    private static func isAppOrSystemBinary(_ path: String) -> Bool {
        path.contains(".app/Contents/")
            || ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
            // Leave room for processes started between the two calls.
            size += size / 8
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            var actual = buffer.count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 3, &buffer, &actual, nil, 0) == 0 {
                return Array(buffer.prefix(actual / MemoryLayout<kinfo_proc>.stride))
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    static func listeningPorts(pid: Int32) -> [UInt16] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let capacity = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
        guard used > 0 else { return [] }
        let count = Int(used) / MemoryLayout<proc_fdinfo>.stride

        var result = Set<UInt16>()
        for fd in fds.prefix(count) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard size == Int32(MemoryLayout<socket_fdinfo>.size),
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_family == AF_INET || info.psi.soi_family == AF_INET6 else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if port > 0 { result.insert(port) }
        }
        return result.sorted()
    }

    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard size == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// The full command line, e.g. "node /Users/me/site/node_modules/.bin/vite --port 4321".
    static func commandLine(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < argc {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return arguments
    }
}

enum Responsibility {
    private typealias Function = @convention(c) (pid_t) -> pid_t

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func responsiblePID(for pid: Int32) -> Int32 {
        guard let function, pid > 0 else { return pid }
        let responsible = function(pid)
        return responsible > 0 ? responsible : pid
    }
}
