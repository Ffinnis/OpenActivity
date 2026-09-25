//
//  ProcessNetworkSampler.swift
//  OpenActivity
//
//  Per-process network rates. macOS has no public API for this, so one long-lived
//  `nettop -P -L 0` child streams cumulative per-process byte counters as CSV blocks
//  (",bytes_in,bytes_out," header, then "name.pid,in,out," rows) and rates are computed from
//  the difference between consecutive blocks using our own clock. Cumulative counters (rather
//  than nettop's -d mode) keep the figures right when a block is late or skipped; nettop keeps
//  counting bytes of sockets that have closed, so the counters only go down on pid reuse.
//
//  nettop fully buffers its output when writing to a pipe (16 KB, i.e. many seconds), so it
//  runs under `script -q /dev/null`, which gives it a pseudo-terminal (line buffered) and
//  relays the output to our pipe unbuffered. That chain also keeps nettop from outliving us:
//  - stop()/deinit and a process-wide atexit handler send SIGTERM to `script`;
//  - if we die without running either (crash, SIGKILL), our pipe's read end closes, `script`
//    dies of SIGPIPE on its next write (at most one interval later);
//  - when `script` dies the pty master closes and nettop, whose controlling terminal it is,
//    receives SIGHUP and exits.
//

import Foundation

final class ProcessNetworkSampler {
    private let interval: Int
    private let queue = DispatchQueue(label: "OpenActivity.ProcessNetworkSampler", qos: .utility)
    private let lock = NSLock()
    private var latestRates: [Int32: (inRate: Double, outRate: Double)] = [:]

    // Confined to `queue`.
    private var wantsRunning = false
    private var process: Process?
    /// script's stdin. Kept open and silent: at EOF script forwards ^D and nettop spins at 100% CPU.
    private var inputPipe: Pipe?
    private var generation = 0
    private var failures = 0
    private var pending = Data()
    private var block: [Int32: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var blockTime: TimeInterval?
    private var previous: [Int32: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var previousTime: TimeInterval?
    private var finishBlockWork: DispatchWorkItem?

    /// nettop only accepts whole seconds.
    init(interval: TimeInterval = 2) {
        self.interval = max(1, Int(interval.rounded()))
    }

    deinit {
        if let process {
            ChildProcessRegistry.remove(process.processIdentifier)
            if process.isRunning { process.terminate() }
        }
    }

    func start() {
        queue.async { [self] in
            guard !wantsRunning else { return }
            wantsRunning = true
            failures = 0
            launch()
        }
    }

    func stop() {
        queue.async { [self] in
            wantsRunning = false
            generation += 1
            terminateProcess()
            resetParser()
            lock.withLock { latestRates = [:] }
        }
    }

    /// Latest bytes/second per pid.
    func rates() -> [Int32: (inRate: Double, outRate: Double)] {
        lock.withLock { latestRates }
    }

    // MARK: - Child process

    private func launch() {
        generation += 1
        let current = generation
        resetParser()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null",
                             "/usr/bin/nettop", "-P", "-L", "0", "-s", String(interval),
                             "-n", "-x", "-t", "external", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.consume(data, generation: current) }
        }
        process.terminationHandler = { [weak self] process in
            ChildProcessRegistry.remove(process.processIdentifier)
            self?.queue.async { self?.childExited(generation: current) }
        }

        do {
            try process.run()
            ChildProcessRegistry.add(process.processIdentifier)
            // The child may already have exited and run its termination handler before we registered it.
            if !process.isRunning { ChildProcessRegistry.remove(process.processIdentifier) }
            self.process = process
            inputPipe = input
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            scheduleRestart()
        }
    }

    private func terminateProcess() {
        guard let process else { return }
        self.process = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
    }

    private func childExited(generation exited: Int) {
        guard exited == generation, wantsRunning else { return }
        // No live source now; better no per-app figures than frozen ones.
        lock.withLock { latestRates = [:] }
        terminateProcess()
        scheduleRestart()
    }

    /// 1, 2, 4 ... 60 seconds; reset once a block parses.
    private func scheduleRestart() {
        let delay = min(60, pow(2, Double(failures)))
        failures += 1
        let current = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsRunning, self.generation == current else { return }
            self.launch()
        }
    }

    // MARK: - Parsing

    private func resetParser() {
        pending.removeAll()
        block.removeAll()
        blockTime = nil
        previous.removeAll()
        previousTime = nil
        finishBlockWork?.cancel()
        finishBlockWork = nil
    }

    private func consume(_ data: Data, generation current: Int) {
        guard current == generation, !data.isEmpty else { return }
        pending.append(data)
        guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[(lastNewline + 1)...])

        for rawLine in complete.split(separator: UInt8(ascii: "\n")) {
            let line = String(decoding: rawLine, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("bytes_in") {
                // A header starts a block (script may prefix it with the "^D" it echoes).
                finishBlock()
                blockTime = ProcessInfo.processInfo.systemUptime
            } else if blockTime != nil, let row = Self.parseRow(line) {
                block[row.pid] = (row.bytesIn, row.bytesOut)
            }
        }

        // nettop writes a block in one burst; finish it once the output goes quiet instead of
        // waiting a whole interval for the next header.
        finishBlockWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishBlock() }
        finishBlockWork = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// "Google Chrome He.1234,5678,910," -> (1234, 5678, 910). Names may contain dots and commas.
    private static func parseRow(_ line: String) -> (pid: Int32, bytesIn: UInt64, bytesOut: UInt64)? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count >= 3,
              let bytesOut = UInt64(fields[fields.count - 1]),
              let bytesIn = UInt64(fields[fields.count - 2])
        else { return nil }
        let name = fields[..<(fields.count - 2)].joined(separator: ",")
        guard let dot = name.lastIndex(of: "."), let pid = Int32(name[name.index(after: dot)...]) else { return nil }
        return (pid, bytesIn, bytesOut)
    }

    private func finishBlock() {
        finishBlockWork?.cancel()
        finishBlockWork = nil
        guard let time = blockTime else { return }
        failures = 0

        var rates: [Int32: (inRate: Double, outRate: Double)] = [:]
        if let previousTime, time - previousTime > 0.2 {
            let elapsed = time - previousTime
            for (pid, now) in block {
                // A pid seen for the first time only sets the baseline.
                guard let before = previous[pid], now.bytesIn >= before.bytesIn, now.bytesOut >= before.bytesOut else { continue }
                let inRate = Double(now.bytesIn - before.bytesIn) / elapsed
                let outRate = Double(now.bytesOut - before.bytesOut) / elapsed
                if inRate > 0 || outRate > 0 { rates[pid] = (inRate, outRate) }
            }
        }
        lock.withLock { latestRates = rates }

        previous = block
        previousTime = time
        block.removeAll(keepingCapacity: true)
        blockTime = nil
    }
}

/// Children still running at exit get SIGTERM from an atexit handler.
private enum ChildProcessRegistry {
    private static let lock = NSLock()
    private static var pids = Set<pid_t>()
    private static var installed = false

    static func add(_ pid: pid_t) {
        lock.withLock {
            pids.insert(pid)
            if !installed {
                installed = true
                atexit { ChildProcessRegistry.terminateAll() }
            }
        }
    }

    static func remove(_ pid: pid_t) {
        lock.withLock { _ = pids.remove(pid) }
    }

    private static func terminateAll() {
        let all = lock.withLock { pids }
        for pid in all { kill(pid, SIGTERM) }
    }
}
