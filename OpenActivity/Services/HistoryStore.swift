//
//  HistoryStore.swift
//  OpenActivity
//
//  Thirty days of system figures and per-app usage in one small SQLite file.
//  Samples are folded into a one-minute accumulator in memory and written once a minute.
//
//  Tables:
//    system_minute  one row per minute the Mac was sampled (averages; disk/network as byte totals)
//    app_minute     per-app usage for the busiest apps of each minute, kept for 26 hours (12 h / 24 h charts)
//    app_hour       the same figures rolled up per hour, kept for 30 days (7 d / 30 d charts, top apps)
//    apps           app id -> name and bundle path; the app tables reference its integer key
//  App tables store integrals (percent·seconds, byte·seconds, joules, bytes) so minutes and hours
//  add up exactly and averages can be taken over any span.
//

import Foundation
import SQLite3

/// Time spans the history charts can show.
enum HistoryRange: String, CaseIterable {
    case hours12, hours24, days7, days30

    var title: String {
        switch self {
        case .hours12: return "12 h"
        case .hours24: return "24 h"
        case .days7: return "7 d"
        case .days30: return "30 d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .hours12: return 12 * 3_600
        case .hours24: return 24 * 3_600
        case .days7: return 7 * 86_400
        case .days30: return 30 * 86_400
        }
    }

    /// Chart resolution, 144–180 points per chart.
    var bucket: TimeInterval {
        switch self {
        case .hours12: return 5 * 60
        case .hours24: return 10 * 60
        case .days7: return 3_600
        case .days30: return 4 * 3_600
        }
    }

    /// Short ranges read per-minute app rows, long ranges the hourly roll-up.
    fileprivate var usesMinuteAppRows: Bool { duration <= HistoryStore.appMinuteRetention - 3_600 }
}

/// System-wide figures kept in history. Units follow `SystemSnapshot`: fractions (0...1) for
/// cpu, gpu and batteryCharge, bytes for memoryUsed, `MemoryPressure.rawValue` (1, 2, 4) for
/// memoryPressure, bytes per second for disk and network, watts for systemPower, °C for cpuTemperature.
enum HistorySeries: String, CaseIterable {
    case cpu, memoryUsed, memoryPressure, gpu, diskRead, diskWrite, netIn, netOut, batteryCharge, systemPower, cpuTemperature

    fileprivate var column: String {
        switch self {
        case .cpu: return "cpu"
        case .memoryUsed: return "mem_used"
        case .memoryPressure: return "mem_pressure"
        case .gpu: return "gpu"
        case .diskRead: return "disk_read_bytes"
        case .diskWrite: return "disk_write_bytes"
        case .netIn: return "net_in_bytes"
        case .netOut: return "net_out_bytes"
        case .batteryCharge: return "battery"
        case .systemPower: return "power"
        case .cpuTemperature: return "cpu_temp"
        }
    }

    /// Byte totals per minute, reported as bytes per second.
    fileprivate var isRate: Bool {
        switch self {
        case .diskRead, .diskWrite, .netIn, .netOut: return true
        default: return false
        }
    }

    /// SQL for the weighted-average numerator and denominator over a set of minute rows.
    fileprivate var averageSQL: (numerator: String, denominator: String) {
        isRate
            ? ("SUM(\(column))", "SUM(seconds)")
            : ("SUM(\(column) * seconds)", "SUM(CASE WHEN \(column) IS NOT NULL THEN seconds END)")
    }

    /// SQL for the value of a single minute row.
    fileprivate var minuteValueSQL: String { isRate ? "\(column) / seconds" : column }
}

struct HistoryPoint {
    var date: Date
    var value: Double
}

/// `value` is an average for cpu (percent of one core), gpu (percent), memory (bytes) and
/// battery (watts), and a total in bytes for disk and network.
struct HistoryAppTotal {
    var appID: String
    var name: String
    var bundlePath: String?
    var value: Double
}

/// Thread-safe: all database work and the minute in progress live on one serial queue.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore(url: HistoryStore.defaultURL)

    /// ~/Library/Application Support/OpenActivity/history.sqlite
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("OpenActivity", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    /// How long system minutes and hourly app totals are kept.
    static let retention: TimeInterval = 30 * 86_400
    /// Per-minute app rows only feed the 12 h and 24 h views.
    static let appMinuteRetention: TimeInterval = 26 * 3_600
    /// Cap on app rows written per minute.
    static let maxAppsPerMinute = 40

    let url: URL
    /// Longest time one sample may stand for. Longer gaps (sleep, a stalled monitor) are left empty.
    private let maxSampleInterval: TimeInterval
    private let queue = DispatchQueue(label: "OpenActivity.HistoryStore", qos: .utility)

    // Everything below is only touched on `queue`.
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var appKeys: [String: AppRecord] = [:]
    private var minute: MinuteAccumulator?
    private var lastSampleTime: TimeInterval?
    /// Newest minute already in the database. Minute rows are written once; a clock stepping back
    /// into a written minute would otherwise double-count the hourly roll-up.
    private var lastWrittenMinute: Int64 = .min
    private var lastPruneTime: TimeInterval = -.infinity
    /// Chart query results. The database only changes once a minute, so views can redraw freely.
    private var results: [String: (time: TimeInterval, value: Any)] = [:]
    /// Tests turn this off to time the queries themselves.
    var cachesResults = true

    convenience init(url: URL) {
        self.init(url: url, maxSampleInterval: 15)
    }

    /// `maxSampleInterval` is exposed for tests that feed sparse synthetic samples.
    init(url: URL, maxSampleInterval: TimeInterval) {
        self.url = url
        self.maxSampleInterval = maxSampleInterval
        queue.sync { open() }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let db { sqlite3_close_v2(db) }
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    // MARK: - Recording

    func record(_ snapshot: SystemSnapshot) {
        let sample = Sample(snapshot)
        queue.async { self.accumulate(sample) }
    }

    /// Writes the minute in progress. Call when the app terminates.
    func flush() {
        queue.sync {
            if let minute { write(minute) }
            minute = nil
        }
    }

    // MARK: - Queries (any thread; synchronized with writes)

    func series(_ series: HistorySeries, range: HistoryRange) -> [HistoryPoint] {
        let bucket = Int64(range.bucket)
        let start = Int64(Date().timeIntervalSince1970 - range.duration)
        let (numerator, denominator) = series.averageSQL
        let sql = """
            SELECT (ts / ?1) * ?1 AS b, \(numerator) / \(denominator) AS v
            FROM system_minute WHERE ts >= ?2 GROUP BY b HAVING v IS NOT NULL ORDER BY b
            """
        return queue.sync {
            cached("series|\(series.rawValue)|\(range.rawValue)") {
                var points: [HistoryPoint] = []
                query(sql, [.int(bucket), .int(start)]) { row in
                    points.append(HistoryPoint(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(row, 0))),
                                               value: sqlite3_column_double(row, 1)))
                }
                return points
            }
        }
    }

    func topApps(by metric: Metric, range: HistoryRange, limit: Int) -> [HistoryAppTotal] {
        guard let figure = AppFigure(metric), limit > 0 else { return [] }
        // Whole hours come from the hourly roll-up; for 12 h / 24 h the partial first hour
        // is added from minute rows, so the span is exact while reading only a few thousand rows.
        let rangeStart = Date().timeIntervalSince1970 - range.duration
        let hourStart: Int64, minuteStart: Int64
        if range.usesMinuteAppRows {
            minuteStart = Int64(rangeStart)
            hourStart = (minuteStart + 3_599) / 3_600 * 3_600
        } else {
            hourStart = Int64(rangeStart) / 3_600 * 3_600
            minuteStart = hourStart
        }
        let column = figure.column
        let valueSQL = figure.kind == .presentAverage ? "SUM(\(column)) / SUM(present_s)" : "SUM(\(column))"
        let sql = """
            SELECT a.app_id, a.name, a.bundle_path, s.v FROM (
                SELECT app, \(valueSQL) AS v FROM (
                    SELECT app, present_s, \(column) FROM app_hour WHERE ts >= ?1
                    UNION ALL
                    SELECT app, present_s, \(column) FROM app_minute WHERE ts >= ?2 AND ts < ?1)
                GROUP BY app HAVING v > 0 ORDER BY v DESC LIMIT ?3) s
            JOIN apps a ON a.id = s.app ORDER BY s.v DESC
            """
        return queue.sync {
            cached("top|\(metric.rawValue)|\(range.rawValue)|\(limit)") {
                var awake = 0.0
                if figure.kind == .timeAverage {
                    query("SELECT SUM(seconds) FROM system_minute WHERE ts >= ?1", [.int(minuteStart)]) { awake = sqlite3_column_double($0, 0) }
                    guard awake > 0 else { return [] }
                }
                var totals: [HistoryAppTotal] = []
                query(sql, [.int(hourStart), .int(minuteStart), .int(Int64(limit))]) { row in
                    let value = sqlite3_column_double(row, 3)
                    totals.append(HistoryAppTotal(appID: Self.text(row, 0) ?? "",
                                                  name: Self.text(row, 1) ?? "",
                                                  bundlePath: Self.text(row, 2),
                                                  value: figure.kind == .timeAverage ? value / awake : value))
                }
                return totals
            }
        }
    }

    /// Per-bucket figures for one app, only for buckets in which it was recorded. Units as in
    /// `AppGroup.value(for:)`: disk and network in bytes per second.
    func appSeries(appID: String, metric: Metric, range: HistoryRange) -> [HistoryPoint] {
        guard let figure = AppFigure(metric) else { return [] }
        let bucket = Int64(range.bucket)
        let (table, start) = appSpan(range)
        let sql = """
            SELECT (ts / ?1) * ?1 AS b, SUM(\(figure.column)), SUM(present_s)
            FROM \(table) WHERE app = ?2 AND ts >= ?3 GROUP BY b ORDER BY b
            """
        return queue.sync {
            guard let key = appKeys[appID]?.key else { return [] }
            return cached("app|\(appID)|\(metric.rawValue)|\(range.rawValue)") {
                var awake: [Int64: Double] = [:]
                if figure.kind != .presentAverage {
                    query("SELECT (ts / ?1) * ?1 AS b, SUM(seconds) FROM system_minute WHERE ts >= ?2 GROUP BY b",
                          [.int(bucket), .int(start)]) { awake[sqlite3_column_int64($0, 0)] = sqlite3_column_double($0, 1) }
                }
                var points: [HistoryPoint] = []
                query(sql, [.int(bucket), .int(key), .int(start)]) { row in
                    let b = sqlite3_column_int64(row, 0)
                    let sum = sqlite3_column_double(row, 1)
                    let present = sqlite3_column_double(row, 2)
                    // Averages over the time the Mac was sampled in the bucket; memory over the time the app ran.
                    let seconds = figure.kind == .presentAverage ? present : max(awake[b] ?? present, present)
                    guard seconds > 0 else { return }
                    points.append(HistoryPoint(date: Date(timeIntervalSince1970: TimeInterval(b)), value: sum / seconds))
                }
                return points
            }
        }
    }

    /// Time-weighted average since the date, including the minute in progress. Rates in bytes/s.
    func average(_ series: HistorySeries, since: Date) -> Double? {
        let start = Self.minuteStart(since.timeIntervalSince1970)
        let (numerator, denominator) = series.averageSQL
        return queue.sync {
            var mean = Mean()
            query("SELECT \(numerator), \(denominator) FROM system_minute WHERE ts >= ?1", [.int(start)]) { row in
                mean.sum = sqlite3_column_double(row, 0)
                mean.weight = sqlite3_column_double(row, 1)
            }
            if let minute, minute.ts >= start { mean.merge(minute.system.mean(series)) }
            return mean.value
        }
    }

    /// Highest one-minute value since the date, including the minute in progress. Rates in bytes/s.
    func peak(_ series: HistorySeries, since: Date) -> Double? {
        let start = Self.minuteStart(since.timeIntervalSince1970)
        return queue.sync {
            var peak: Double?
            query("SELECT MAX(\(series.minuteValueSQL)) FROM system_minute WHERE ts >= ?1", [.int(start)]) { row in
                peak = Self.double(row, 0)
            }
            if let minute, minute.ts >= start, let value = minute.system.mean(series).value {
                peak = max(peak ?? value, value)
            }
            return peak
        }
    }

    func networkBytes(since: Date) -> (received: UInt64, sent: UInt64) {
        let start = Self.minuteStart(since.timeIntervalSince1970)
        return queue.sync {
            var received = 0.0, sent = 0.0
            query("SELECT SUM(net_in_bytes), SUM(net_out_bytes) FROM system_minute WHERE ts >= ?1", [.int(start)]) { row in
                received = sqlite3_column_double(row, 0)
                sent = sqlite3_column_double(row, 1)
            }
            if let minute, minute.ts >= start {
                received += minute.system.netIn
                sent += minute.system.netOut
            }
            return (UInt64(max(0, received)), UInt64(max(0, sent)))
        }
    }

    func diskBytesWritten(since: Date) -> UInt64 {
        let start = Self.minuteStart(since.timeIntervalSince1970)
        return queue.sync {
            var written = 0.0
            query("SELECT SUM(disk_write_bytes) FROM system_minute WHERE ts >= ?1", [.int(start)]) { written = sqlite3_column_double($0, 0) }
            if let minute, minute.ts >= start { written += minute.system.diskWrite }
            return UInt64(max(0, written))
        }
    }

    /// Size on disk of the database and its write-ahead log.
    var fileSize: UInt64 {
        [url.path, url.path + "-wal"].reduce(0) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
            return total + size
        }
    }

    /// Deletes all history.
    func clear() {
        queue.sync {
            minute = nil
            results = [:]
            guard db != nil else { return }
            exec("DELETE FROM system_minute; DELETE FROM app_minute; DELETE FROM app_hour; DELETE FROM apps;")
            appKeys = [:]
            lastWrittenMinute = .min
            exec("VACUUM")
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// The cached result for the key if it is younger than a minute, otherwise a fresh one. On `queue`.
    private func cached<T>(_ key: String, _ compute: () -> T) -> T {
        let now = Date().timeIntervalSince1970
        if cachesResults, let hit = results[key], now - hit.time < 60, hit.time <= now, let value = hit.value as? T {
            return value
        }
        let value = compute()
        if cachesResults { results[key] = (now, value) }
        return value
    }

    // MARK: - Accumulation

    private func accumulate(_ sample: Sample) {
        // No database (another copy holds the lock, or it couldn't be opened): nothing to record into.
        guard db != nil else { return }
        let time = sample.time
        let interval: TimeInterval
        if let last = lastSampleTime {
            guard time != last else { return }
            // Samples arriving out of order (clock changes) count as a fresh start.
            interval = time > last ? min(time - last, maxSampleInterval) : min(2, maxSampleInterval)
        } else {
            interval = min(2, maxSampleInterval)
        }
        lastSampleTime = time

        let ts = Self.minuteStart(time)
        // `ts + 300` rather than `lastWrittenMinute - 300`: the marker is Int64.min when nothing was written.
        if ts + 300 < lastWrittenMinute {
            // The clock was set back after running ahead: drop the rows from the "future" so
            // recording resumes now instead of after that date.
            discardFutureRows(now: time)
        }
        guard ts > lastWrittenMinute else { return }
        if minute?.ts != ts {
            if let minute { write(minute) }
            minute = MinuteAccumulator(ts: ts)
        }
        minute?.add(sample, interval: interval)

        if time - lastPruneTime >= 3_600 {
            lastPruneTime = time
            prune(now: time)
        }
    }

    private func write(_ minute: MinuteAccumulator) {
        guard db != nil, minute.system.seconds > 0, minute.ts > lastWrittenMinute else { return }
        results = [:]
        let system = minute.system
        guard exec("BEGIN IMMEDIATE") else { return }
        var ok = run("""
            INSERT OR REPLACE INTO system_minute (ts, seconds, cpu, mem_used, mem_pressure, gpu,
                disk_read_bytes, disk_write_bytes, net_in_bytes, net_out_bytes, battery, power, cpu_temp)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            """, [.int(minute.ts), .double(system.seconds),
                  .double(system.cpu.value), .double(system.memUsed.value?.rounded()), .double(system.pressure.value),
                  .double(system.gpu.value),
                  .double(system.diskRead.rounded()), .double(system.diskWrite.rounded()),
                  .double(system.netIn.rounded()), .double(system.netOut.rounded()),
                  .double(system.battery.value), .double(system.power.value), .double(system.cpuTemp.value)])

        let hour = minute.ts / 3_600 * 3_600
        for (id, app) in minute.busiestApps(limit: Self.maxAppsPerMinute) where ok {
            guard let key = appKey(id: id, name: app.name, bundlePath: app.bundlePath) else { ok = false; break }
            // Integral figures are rounded to whole units; SQLite then stores them as compact integers.
            let values: [Binding] = [.double(app.present), .double(app.cpu.rounded()), .double(app.memory.rounded()),
                                     .double(app.gpu.rounded()), .double(app.energy),
                                     .double(app.disk.rounded()), .double(app.network.rounded())]
            ok = run("""
                INSERT OR REPLACE INTO app_minute (ts, app, present_s, cpu_s, mem_s, gpu_s, energy, disk_bytes, net_bytes)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                """, [.int(minute.ts), .int(key)] + values)
                && run("""
                INSERT INTO app_hour (ts, app, present_s, cpu_s, mem_s, gpu_s, energy, disk_bytes, net_bytes)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                ON CONFLICT (ts, app) DO UPDATE SET
                    present_s = present_s + excluded.present_s, cpu_s = cpu_s + excluded.cpu_s,
                    mem_s = mem_s + excluded.mem_s, gpu_s = gpu_s + excluded.gpu_s,
                    energy = energy + excluded.energy, disk_bytes = disk_bytes + excluded.disk_bytes,
                    net_bytes = net_bytes + excluded.net_bytes
                """, [.int(hour), .int(key)] + values)
        }
        if ok && exec("COMMIT") {
            lastWrittenMinute = minute.ts
        } else {
            // A failed COMMIT (e.g. disk full) rolls back too; keys handed out inside it are gone.
            exec("ROLLBACK")
            loadAppKeys()
        }
    }

    private func prune(now: TimeInterval) {
        guard db != nil else { return }
        results = [:]
        let oldest = Int64(now - Self.retention - 3_600)
        let oldestMinuteApps = Int64(now - Self.appMinuteRetention)
        guard exec("BEGIN IMMEDIATE") else { return }
        var ok = run("DELETE FROM system_minute WHERE ts < ?1", [.int(oldest)])
            && run("DELETE FROM app_minute WHERE ts < ?1", [.int(oldestMinuteApps)])
            && run("DELETE FROM app_hour WHERE ts < ?1", [.int(oldest)])
        ok = ok && run("""
            DELETE FROM apps WHERE id NOT IN (SELECT app FROM app_hour) AND id NOT IN (SELECT app FROM app_minute)
            """, [])
        let removedApps = ok && sqlite3_changes(db) > 0
        if !(ok && exec("COMMIT")) {
            exec("ROLLBACK")
            loadAppKeys()
        } else if removedApps {
            loadAppKeys()
        }
        exec("PRAGMA incremental_vacuum")
    }

    /// Integer key for the app, inserting or renaming its row when needed.
    private func appKey(id: String, name: String, bundlePath: String?) -> Int64? {
        if let record = appKeys[id], record.name == name, record.bundlePath == bundlePath { return record.key }
        var key: Int64?
        let ok = query("""
            INSERT INTO apps (app_id, name, bundle_path) VALUES (?1, ?2, ?3)
            ON CONFLICT (app_id) DO UPDATE SET name = excluded.name, bundle_path = excluded.bundle_path
            RETURNING id
            """, [.text(id), .text(name), .text(bundlePath)]) { key = sqlite3_column_int64($0, 0) }
        guard ok, let key else { return nil }
        appKeys[id] = AppRecord(key: key, name: name, bundlePath: bundlePath)
        return key
    }

    private func loadAppKeys() {
        appKeys = [:]
        query("SELECT id, app_id, name, bundle_path FROM apps", []) { row in
            guard let id = Self.text(row, 1) else { return }
            self.appKeys[id] = AppRecord(key: sqlite3_column_int64(row, 0), name: Self.text(row, 2) ?? "", bundlePath: Self.text(row, 3))
        }
    }

    /// Table and first timestamp to read for a range. Hourly rows start at the hour containing the range start.
    private func appSpan(_ range: HistoryRange) -> (table: String, start: Int64) {
        let start = Date().timeIntervalSince1970 - range.duration
        return range.usesMinuteAppRows ? ("app_minute", Int64(start)) : ("app_hour", Int64(start) / 3_600 * 3_600)
    }

    private static func minuteStart(_ time: TimeInterval) -> Int64 { Int64((time / 60).rounded(.down)) * 60 }

    // MARK: - SQLite

    private static let schema = """
        CREATE TABLE IF NOT EXISTS system_minute (
            ts INTEGER PRIMARY KEY, seconds REAL NOT NULL,
            cpu REAL, mem_used REAL, mem_pressure REAL, gpu REAL,
            disk_read_bytes REAL NOT NULL, disk_write_bytes REAL NOT NULL,
            net_in_bytes REAL NOT NULL, net_out_bytes REAL NOT NULL,
            battery REAL, power REAL, cpu_temp REAL);
        CREATE TABLE IF NOT EXISTS apps (
            id INTEGER PRIMARY KEY, app_id TEXT NOT NULL UNIQUE, name TEXT NOT NULL, bundle_path TEXT);
        CREATE TABLE IF NOT EXISTS app_minute (
            ts INTEGER NOT NULL, app INTEGER NOT NULL,
            present_s REAL NOT NULL, cpu_s REAL NOT NULL, mem_s REAL NOT NULL, gpu_s REAL NOT NULL,
            energy REAL NOT NULL, disk_bytes REAL NOT NULL, net_bytes REAL NOT NULL,
            PRIMARY KEY (ts, app)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS app_hour (
            ts INTEGER NOT NULL, app INTEGER NOT NULL,
            present_s REAL NOT NULL, cpu_s REAL NOT NULL, mem_s REAL NOT NULL, gpu_s REAL NOT NULL,
            energy REAL NOT NULL, disk_bytes REAL NOT NULL, net_bytes REAL NOT NULL,
            PRIMARY KEY (ts, app)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS app_hour_by_app ON app_hour (app, ts);
        PRAGMA user_version = 1;
        """

    /// Held for the life of the store; a second running copy of the app records nothing rather than
    /// adding its own figures on top of the first one's hourly totals.
    private var lockDescriptor: Int32 = -1

    private func open() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("HistoryStore: cannot create %@: %@", url.deletingLastPathComponent().path, error.localizedDescription)
        }
        lockDescriptor = Darwin.open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            NSLog("HistoryStore: another copy of OpenActivity is recording history; this one will not")
            return
        }
        switch openDatabase() {
        case .opened:
            return
        case .unavailable:
            // Locked by another copy of the app, unreadable, or written by a newer version:
            // leave the file alone and run without history this time.
            NSLog("HistoryStore: history disabled for this session, %@ left untouched", url.path)
        case .corrupt:
            NSLog("HistoryStore: %@ is damaged, recreating it", url.path)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            if openDatabase() != .opened { NSLog("HistoryStore: history disabled") }
        }
    }

    private enum OpenResult { case opened, corrupt, unavailable }

    private func openDatabase() -> OpenResult {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let code = handle.map { sqlite3_errcode($0) & 0xff } ?? SQLITE_CANTOPEN
            if let handle { sqlite3_close_v2(handle) }
            return code == SQLITE_CORRUPT || code == SQLITE_NOTADB ? .corrupt : .unavailable
        }
        db = handle
        // Before anything else, so a writer elsewhere makes us wait instead of fail.
        sqlite3_busy_timeout(handle, 2_000)

        var version: Int64 = -1
        guard query("PRAGMA user_version", [], row: { version = sqlite3_column_int64($0, 0) }) else {
            return failOpen()
        }
        guard version == 0 || version == 1 else {
            closeDatabase()
            return .unavailable
        }
        var integrity = ""
        let ok = exec("PRAGMA auto_vacuum = INCREMENTAL") // Only takes effect before the first table exists.
            && exec("PRAGMA journal_mode = WAL")
            && exec("PRAGMA synchronous = NORMAL")
            && exec(Self.schema)
            && query("PRAGMA quick_check(1)", []) { integrity = Self.text($0, 0) ?? "" }
        guard ok else { return failOpen() }
        guard integrity == "ok" else {
            closeDatabase()
            return .corrupt
        }
        loadAppKeys()
        discardFutureRows(now: Date().timeIntervalSince1970)
        return .opened
    }

    /// Removes rows stamped after `now` (left by a clock that ran ahead) and resets the newest-minute marker.
    private func discardFutureRows(now: TimeInterval) {
        let limit = Int64(now) + 60
        if let pending = minute, pending.ts > limit { minute = nil }
        lastPruneTime = -.infinity
        if db != nil, exec("BEGIN IMMEDIATE") {
            // Hourly rows start at the top of the hour, so the future minutes inside the current hour
            // are taken back out of them (app_minute holds exactly what was added) before deleting.
            let ok = run("""
                UPDATE app_hour SET
                    present_s = app_hour.present_s - f.present_s, cpu_s = app_hour.cpu_s - f.cpu_s,
                    mem_s = app_hour.mem_s - f.mem_s, gpu_s = app_hour.gpu_s - f.gpu_s,
                    energy = app_hour.energy - f.energy, disk_bytes = app_hour.disk_bytes - f.disk_bytes,
                    net_bytes = app_hour.net_bytes - f.net_bytes
                FROM (SELECT ts / 3600 * 3600 AS hour, app, SUM(present_s) AS present_s, SUM(cpu_s) AS cpu_s,
                             SUM(mem_s) AS mem_s, SUM(gpu_s) AS gpu_s, SUM(energy) AS energy,
                             SUM(disk_bytes) AS disk_bytes, SUM(net_bytes) AS net_bytes
                      FROM app_minute WHERE ts > ?1 GROUP BY hour, app) AS f
                WHERE app_hour.ts = f.hour AND app_hour.app = f.app AND app_hour.ts <= ?1
                """, [.int(limit)])
                && run("DELETE FROM app_hour WHERE ts > ?1 OR present_s <= 0", [.int(limit)])
                && run("DELETE FROM system_minute WHERE ts > ?1", [.int(limit)])
                && run("DELETE FROM app_minute WHERE ts > ?1", [.int(limit)])
            if !(ok && exec("COMMIT")) { exec("ROLLBACK") }
        }
        results = [:]
        lastWrittenMinute = .min
        _ = query("SELECT MAX(ts) FROM system_minute", []) { row in
            if sqlite3_column_type(row, 0) != SQLITE_NULL { self.lastWrittenMinute = sqlite3_column_int64(row, 0) }
        }
    }

    /// Closes after a failed open step, telling a damaged file apart from a busy or unreadable one.
    private func failOpen() -> OpenResult {
        let code = db.map { sqlite3_errcode($0) & 0xff } ?? SQLITE_ERROR
        closeDatabase()
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB ? .corrupt : .unavailable
    }

    private func closeDatabase() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements = [:]
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private enum Binding {
        case int(Int64)
        case double(Double?)
        case text(String?)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            NSLog("HistoryStore: %@ (%@)", message.map { String(cString: $0) } ?? "error", sql)
            sqlite3_free(message)
            return false
        }
        return true
    }

    /// Cached prepared statement for the SQL text.
    private func statement(_ sql: String) -> OpaquePointer? {
        if let cached = statements[sql] { return cached }
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK, let statement else {
            NSLog("HistoryStore: prepare failed: %@ (%@)", String(cString: sqlite3_errmsg(db)), sql)
            return nil
        }
        statements[sql] = statement
        return statement
    }

    /// Runs the statement, calling `row` for every result row. Returns false on error.
    @discardableResult
    private func query(_ sql: String, _ bindings: [Binding], row: (OpaquePointer) -> Void) -> Bool {
        guard let statement = statement(sql) else { return false }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch binding {
            case .int(let value): rc = sqlite3_bind_int64(statement, index, value)
            case .double(let value?) where value.isFinite: rc = sqlite3_bind_double(statement, index, value)
            case .double: rc = sqlite3_bind_null(statement, index)
            case .text(let value?): rc = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .text(nil): rc = sqlite3_bind_null(statement, index)
            }
            guard rc == SQLITE_OK else {
                NSLog("HistoryStore: bind failed: %@", String(cString: sqlite3_errmsg(db)))
                return false
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return true
            default:
                NSLog("HistoryStore: %@ (%@)", String(cString: sqlite3_errmsg(db)), sql)
                return false
            }
        }
    }

    private func run(_ sql: String, _ bindings: [Binding]) -> Bool {
        query(sql, bindings) { _ in }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private static func double(_ row: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : sqlite3_column_double(row, column)
    }
}

// MARK: - In-memory minute

private struct AppRecord {
    var key: Int64
    var name: String
    var bundlePath: String?
}

/// Per-app figure: which app-table column feeds a metric and how it is averaged.
private struct AppFigure {
    enum Kind { case timeAverage, presentAverage, total }
    var column: String
    var kind: Kind

    init?(_ metric: Metric) {
        switch metric {
        case .cpu: (column, kind) = ("cpu_s", .timeAverage)
        case .gpu: (column, kind) = ("gpu_s", .timeAverage)
        case .battery: (column, kind) = ("energy", .timeAverage)
        case .memory: (column, kind) = ("mem_s", .presentAverage)
        case .disk: (column, kind) = ("disk_bytes", .total)
        case .network: (column, kind) = ("net_bytes", .total)
        default: return nil
        }
    }
}

/// The figures of one snapshot that history keeps, copied off the Monitor's queue.
private struct Sample {
    struct App {
        var id: String
        var name: String
        var bundlePath: String?
        var cpu = 0.0, memory = 0.0, disk = 0.0, network = 0.0, gpu = 0.0, power = 0.0
    }

    var time: TimeInterval
    var cpu, memUsed, pressure, gpu: Double
    var diskRead, diskWrite, netIn, netOut: Double
    var battery, power, cpuTemp: Double?
    var apps: [App]

    init(_ snapshot: SystemSnapshot) {
        time = snapshot.date.timeIntervalSince1970
        cpu = snapshot.cpu.total
        memUsed = Double(snapshot.memory.used)
        pressure = Double(snapshot.memory.pressure.rawValue)
        gpu = snapshot.gpu.utilization
        diskRead = snapshot.disk.readRate
        diskWrite = snapshot.disk.writeRate
        netIn = snapshot.network.inRate
        netOut = snapshot.network.outRate
        battery = snapshot.battery.isPresent ? snapshot.battery.charge : nil
        power = snapshot.battery.isPresent || snapshot.battery.systemPower > 0 ? snapshot.battery.systemPower : nil
        cpuTemp = snapshot.sensors.cpuTemperature
        apps = []
        apps.reserveCapacity(snapshot.apps.count)
        for group in snapshot.apps {
            var app = App(id: group.id, name: group.name, bundlePath: group.bundlePath)
            for process in group.processes {
                app.cpu += process.cpuPercent
                app.memory += Double(process.memory)
                app.disk += process.diskReadRate + process.diskWriteRate
                app.network += process.netInRate + process.netOutRate
                app.gpu += process.gpuPercent
                app.power += process.power
            }
            // Idle helpers can never reach the per-minute thresholds; don't carry them around.
            if app.cpu > 0.05 || app.memory >= 16 * 1_048_576 || app.disk > 0 || app.network > 0 || app.gpu > 0 || app.power > 0.01 {
                apps.append(app)
            }
        }
    }
}

/// Time-weighted mean of an optional figure.
private struct Mean {
    var sum = 0.0
    var weight = 0.0

    mutating func add(_ value: Double?, _ seconds: Double) {
        guard let value, value.isFinite else { return }
        sum += value * seconds
        weight += seconds
    }

    mutating func merge(_ other: Mean) {
        sum += other.sum
        weight += other.weight
    }

    var value: Double? { weight > 0 ? sum / weight : nil }
}

private struct SystemMinute {
    var seconds = 0.0
    var cpu = Mean(), memUsed = Mean(), pressure = Mean(), gpu = Mean()
    var battery = Mean(), power = Mean(), cpuTemp = Mean()
    /// Bytes transferred during the minute.
    var diskRead = 0.0, diskWrite = 0.0, netIn = 0.0, netOut = 0.0

    func mean(_ series: HistorySeries) -> Mean {
        switch series {
        case .cpu: return cpu
        case .memoryUsed: return memUsed
        case .memoryPressure: return pressure
        case .gpu: return gpu
        case .batteryCharge: return battery
        case .systemPower: return power
        case .cpuTemperature: return cpuTemp
        case .diskRead: return Mean(sum: diskRead, weight: seconds)
        case .diskWrite: return Mean(sum: diskWrite, weight: seconds)
        case .netIn: return Mean(sum: netIn, weight: seconds)
        case .netOut: return Mean(sum: netOut, weight: seconds)
        }
    }
}

/// Integrals over the minute: percent·seconds, byte·seconds, joules and bytes.
private struct AppMinute {
    var name: String
    var bundlePath: String?
    var present = 0.0
    var cpu = 0.0, memory = 0.0, gpu = 0.0, energy = 0.0, disk = 0.0, network = 0.0
}

private struct MinuteAccumulator {
    let ts: Int64
    var system = SystemMinute()
    var apps: [String: AppMinute] = [:]

    mutating func add(_ sample: Sample, interval dt: TimeInterval) {
        system.seconds += dt
        system.cpu.add(sample.cpu, dt)
        system.memUsed.add(sample.memUsed, dt)
        system.pressure.add(sample.pressure, dt)
        system.gpu.add(sample.gpu, dt)
        system.battery.add(sample.battery, dt)
        system.power.add(sample.power, dt)
        system.cpuTemp.add(sample.cpuTemp, dt)
        system.diskRead += sample.diskRead * dt
        system.diskWrite += sample.diskWrite * dt
        system.netIn += sample.netIn * dt
        system.netOut += sample.netOut * dt

        for app in sample.apps {
            var minute = apps[app.id] ?? AppMinute(name: app.name, bundlePath: app.bundlePath)
            minute.name = app.name
            minute.bundlePath = app.bundlePath
            minute.present += dt
            minute.cpu += app.cpu * dt
            minute.memory += app.memory * dt
            minute.gpu += app.gpu * dt
            minute.energy += app.power * dt
            minute.disk += app.disk * dt
            minute.network += app.network * dt
            apps[app.id] = minute
        }
    }

    /// Apps worth keeping this minute: above small thresholds, at most `limit`, taking the
    /// leaders of every figure in turn so a heavy disk or network user is never crowded out.
    func busiestApps(limit: Int) -> [(String, AppMinute)] {
        let seconds = max(system.seconds, 1)
        let candidates = apps.filter { _, app in
            app.cpu / seconds >= 0.5 || app.memory / max(app.present, 1) >= 50 * 1_048_576
                || app.disk >= 1_048_576 || app.network >= 256 * 1_024
                || app.gpu / seconds >= 0.5 || app.energy / seconds >= 0.1
        }
        guard candidates.count > limit else { return candidates.map { ($0.key, $0.value) } }
        let rankings: [[(key: String, value: AppMinute)]] = [\AppMinute.cpu, \.memory, \.disk, \.network, \.gpu, \.energy].map { figure in
            candidates.sorted { $0.value[keyPath: figure] > $1.value[keyPath: figure] }
        }
        var chosen: [(String, AppMinute)] = []
        var seen = Set<String>()
        var rank = 0
        while chosen.count < limit {
            for ranking in rankings where rank < ranking.count && chosen.count < limit {
                let entry = ranking[rank]
                if seen.insert(entry.key).inserted { chosen.append((entry.key, entry.value)) }
            }
            rank += 1
        }
        return chosen
    }
}
