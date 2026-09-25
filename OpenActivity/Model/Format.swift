//
//  Format.swift
//  OpenActivity
//
//  How figures read on screen: "52.63 GB", "737 kB/s", "27%", "2h 46m".
//

import Foundation

enum Format {
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    private static let fileFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    /// Memory sizes use binary units like Activity Monitor ("1.69 GB").
    static func memory(_ bytes: UInt64) -> String {
        memoryFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func memory(_ bytes: Double) -> String {
        memory(UInt64(max(0, bytes)))
    }

    /// Disk and network amounts use decimal units like Finder ("479.72 GB").
    static func bytes(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 KB" }
        return fileFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func bytes(_ bytes: Double) -> String {
        self.bytes(UInt64(max(0, bytes)))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        switch value {
        case ..<1_000: return "\(Int(value.rounded())) B/s"
        case ..<1_000_000: return "\(Int((value / 1_000).rounded())) kB/s"
        case ..<10_000_000: return String(format: "%.1f MB/s", value / 1_000_000)
        case ..<1_000_000_000: return "\(Int((value / 1_000_000).rounded())) MB/s"
        default: return String(format: "%.2f GB/s", value / 1_000_000_000)
        }
    }

    /// A 0...1 fraction as a whole percentage.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "–" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Percent of one core ("18.2%"), the way per-process CPU is usually shown.
    static func cpu(_ percentOfCore: Double) -> String {
        guard percentOfCore.isFinite else { return "–" }
        if percentOfCore >= 100 { return "\(Int(percentOfCore.rounded()))%" }
        return String(format: "%.1f%%", percentOfCore)
    }

    static func watts(_ watts: Double) -> String {
        guard watts.isFinite else { return "–" }
        if watts < 1 { return "\(Int((watts * 1000).rounded())) mW" }
        return String(format: "%.1f W", watts)
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "–" }
        return "\(Int(celsius.rounded()))°"
    }

    static func rpm(_ rpm: Double) -> String {
        numberFormatter.string(from: NSNumber(value: Int(rpm.rounded()))) ?? "\(Int(rpm))"
    }

    static func number(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// Compact durations: "45s", "12 min", "2h 46m", "3d 4h".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total)s"
    }

    /// Longer, spoken durations: "45 min", "2 hours", "3 days".
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60
        if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }

    static func cpuTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d.%02d", minutes, secs, Int((seconds - Double(total)) * 100))
    }

    static func processes(_ count: Int) -> String {
        count == 1 ? "1 process" : "\(Format.number(count)) processes"
    }
}
