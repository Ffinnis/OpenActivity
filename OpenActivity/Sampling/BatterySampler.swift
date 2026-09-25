//
//  BatterySampler.swift
//  OpenActivity
//
//  Battery state from IOPowerSources, plus health, temperature and power draw
//  from the AppleSmartBattery service.
//

import Foundation
import IOKit
import IOKit.ps

final class BatterySampler {
    private var smartBattery: io_service_t = 0
    private var lookedUpSmartBattery = false

    init() {}

    deinit {
        if smartBattery != 0 { IOObjectRelease(smartBattery) }
    }

    func sample() -> BatteryStats {
        var stats = BatteryStats()
        readPowerSources(into: &stats)
        readSmartBattery(into: &stats)
        if stats.isPluggedIn || !stats.isPresent,
           let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = (details[kIOPSPowerAdapterWattsKey] as? NSNumber)?.doubleValue, watts > 0 {
            stats.adapterWatts = watts
        }
        return stats
    }

    // MARK: - IOPowerSources

    private func readPowerSources(into stats: inout BatteryStats) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }

        stats.isPluggedIn = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSACPowerValue

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true else { continue }

            stats.isPresent = true
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            stats.charge = maximum > 0 ? min(1, max(0, current / maximum)) : 0
            stats.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            stats.isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            stats.isFullyCharged = description[kIOPSIsChargedKey] as? Bool ?? false

            if stats.isCharging {
                stats.timeRemaining = Self.minutes(description[kIOPSTimeToFullChargeKey])
            } else if !stats.isPluggedIn {
                let estimate = IOPSGetTimeRemainingEstimate()
                stats.timeRemaining = estimate > 0 ? estimate : Self.minutes(description[kIOPSTimeToEmptyKey])
            }

            if let condition = description[kIOPSBatteryHealthConditionKey] as? String, !condition.isEmpty {
                stats.condition = condition
            }
            break
        }
    }

    /// Converts an IOPS minutes figure to seconds; -1 (still estimating) and 0 mean unknown.
    private static func minutes(_ value: Any?) -> TimeInterval? {
        guard let minutes = (value as? NSNumber)?.intValue, minutes > 0 else { return nil }
        return TimeInterval(minutes * 60)
    }

    // MARK: - AppleSmartBattery

    private func readSmartBattery(into stats: inout BatteryStats) {
        if !lookedUpSmartBattery {
            lookedUpSmartBattery = true
            smartBattery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard smartBattery != 0 else { return }

        stats.cycleCount = integer("CycleCount") ?? 0
        if let raw = integer("AppleRawMaxCapacity") ?? integer("NominalChargeCapacity"),
           let design = integer("DesignCapacity"), design > 0 {
            stats.health = min(1, max(0, Double(raw) / Double(design)))
        }
        if let centi = integer("Temperature"), centi != 0 {
            stats.temperature = Double(centi) / 100
        }

        if stats.isPluggedIn,
           let telemetry = property("PowerTelemetryData") as? [String: Any],
           let milliwatts = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue, milliwatts > 0 {
            stats.systemPower = milliwatts / 1000
        } else if let millivolts = integer("Voltage"),
                  let milliamps = integer("InstantAmperage") ?? integer("Amperage") {
            stats.systemPower = abs(Double(millivolts) * Double(milliamps)) / 1_000_000
        }

        if stats.condition == "Normal", let failure = integer("PermanentFailureStatus"), failure != 0 {
            stats.condition = "Permanent Failure"
        }
    }

    private func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(smartBattery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Reads a signed figure. The registry stores negative currents as huge unsigned numbers,
    /// so the raw 64-bit pattern is reinterpreted as signed.
    private func integer(_ key: String) -> Int? {
        guard let number = property(key) as? NSNumber else { return nil }
        return Int(truncatingIfNeeded: number.int64Value)
    }
}
