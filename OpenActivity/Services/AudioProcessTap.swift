//
//  AudioProcessTap.swift
//  OpenActivity
//
//  One Core Audio process tap routed through a private aggregate device whose
//  IOProc plays the tapped audio back to the output device with a gain applied.
//  Also hosts the small HAL helpers and the audio-capture permission check
//  shared with AudioVolumeController.
//

import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenActivity", category: "AudioTap")

// MARK: - Errors

/// A failed Core Audio call: the operation that failed and its OSStatus.
struct AudioHALError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String { "\(operation) failed (\(AudioHAL.fourCC(status)))" }
}

// MARK: - HAL property helpers

/// Thin, throwing wrappers over the AudioObject property API.
enum AudioHAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw AudioHALError(operation: operation(), status: status) }
    }

    /// Reads a fixed-size (POD) property value.
    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "get '\(fourCC(selector))'")
        return value
    }

    /// Reads a property holding an array of AudioObjectIDs.
    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size '\(fourCC(selector))'")
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids), "get '\(fourCC(selector))'")
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Reads a CFString property (returned +1 by the HAL).
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var address = address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "get '\(fourCC(selector))'")
        guard let value else { throw AudioHALError(operation: "get '\(fourCC(selector))'", status: kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    /// Channel count of every buffer the device's IOProc sees in `scope`.
    static func bufferChannelCounts(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "size stream configuration")
        guard Int(size) >= MemoryLayout<AudioBufferList>.size else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "get stream configuration")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Virtual formats of the device's streams in `scope`.
    static func streamFormats(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamBasicDescription] {
        try objectIDs(device, kAudioDevicePropertyStreams, scope: scope).map {
            try value($0, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        }
    }

    /// The current default output device and its UID.
    static func defaultOutputDevice() throws -> (id: AudioObjectID, uid: String) {
        let id = try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                           initial: AudioObjectID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else {
            throw AudioHALError(operation: "default output device", status: kAudioHardwareBadDeviceError)
        }
        return (id, try string(id, kAudioDevicePropertyDeviceUID))
    }

    static func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    /// Renders an OSStatus / selector as its four-char code when printable.
    static func fourCC<T: BinaryInteger>(_ code: T) -> String {
        let value = UInt32(truncatingIfNeeded: code)
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(Int32(bitPattern: value)) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Audio capture permission

/// Preflights/requests the "audio capture" TCC permission process taps need.
///
/// There is no public API for this, so it goes through TCC's SPI (resolved at
/// runtime). Without it a denied tap silently yields zeros, which combined with
/// `.mutedWhenTapped` would silence the app instead of attenuating it.
enum AudioCapturePermission {
    enum Status { case authorized, denied, undetermined, unavailable }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: PreflightFunction? = framework
        .flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: PreflightFunction.self) }
    private static let requestAccess: RequestFunction? = framework
        .flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: RequestFunction.self) }

    static var status: Status {
        guard let preflight else { return .unavailable }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt; `completion` runs on an arbitrary queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestAccess else { return completion(true) }
        requestAccess(service, nil) { completion($0) }
    }
}

// MARK: - Gain

/// Gain shared between the controlling queue and the real-time IO thread.
private final class TapGain: @unchecked Sendable {
    private let target: Atomic<UInt32>
    /// Gain reached at the end of the previous IO cycle. Touched only by the IO thread.
    let rendered: UnsafeMutablePointer<Float>

    init(_ gain: Float) {
        target = Atomic(gain.bitPattern)
        rendered = .allocate(capacity: 1)
        rendered.initialize(to: gain)
    }

    deinit { rendered.deallocate() }

    var value: Float {
        get { Float(bitPattern: target.load(ordering: .relaxed)) }
        set { target.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

// MARK: - Process tap

/// Mutes a set of Core Audio process objects and replays their stereo mix on
/// an output device, scaled by `gain`. Torn down by `invalidate()` or deinit,
/// after which the processes play untouched again.
final class AudioProcessTap {
    private(set) var processObjectIDs: [AudioObjectID]
    let outputDeviceUID: String

    var gain: Float {
        get { gainState.value }
        set { gainState.value = newValue.isFinite ? min(max(newValue, 0), 1) : 1 }
    }

    private let tapDescription: CATapDescription
    private let gainState: TapGain
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    /// Builds the tap, the aggregate device and the IOProc, and starts IO.
    /// Anything partially created is destroyed again if a step fails.
    init(processObjectIDs: [AudioObjectID], outputDeviceUID: String, gain: Float, name: String) throws {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        gainState = TapGain(gain.isFinite ? min(max(gain, 0), 1) : 1)

        tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.uuid = UUID()
        tapDescription.name = "OpenActivity volume: \(name)"
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true

        do {
            try activate()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    /// Retargets the live tap at a new process list without rebuilding it.
    /// Returns false if the HAL refused; the caller should rebuild instead.
    func updateProcesses(_ ids: [AudioObjectID]) -> Bool {
        guard tapID != kAudioObjectUnknown else { return false }
        let previous = tapDescription.processes
        tapDescription.processes = ids
        var address = AudioHAL.address(kAudioTapPropertyDescription)
        var reference: CATapDescription = tapDescription
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else {
            tapDescription.processes = previous
            logger.error("Updating tap processes failed (\(AudioHAL.fourCC(status), privacy: .public))")
            return false
        }
        processObjectIDs = ids
        return true
    }

    /// Stops IO and destroys the IOProc, aggregate device and tap. Idempotent.
    func invalidate() {
        if isRunning, let ioProcID {
            log(AudioDeviceStop(aggregateID, ioProcID), "AudioDeviceStop")
            isRunning = false
        }
        if let ioProcID {
            log(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "AudioDeviceDestroyIOProcID")
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            log(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            log(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: Setup

    private func activate() throws {
        try AudioHAL.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")

        let tapFormat = try AudioHAL.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard AudioHAL.isFloat32(tapFormat) else {
            throw AudioHALError(operation: "tap format check", status: kAudioHardwareUnsupportedOperationError)
        }
        let tapBufferCount = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            ? Int(tapFormat.mChannelsPerFrame) : 1

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenActivity Volume",
            kAudioAggregateDeviceUIDKey: "com.openactivity.volume.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try AudioHAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
                           "AudioHardwareCreateAggregateDevice")

        // The IOProc sees the sub-device's input buffers (if any) first, then the tap's.
        let inputBuffers = try AudioHAL.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let outputBuffers = try AudioHAL.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        guard inputBuffers.count >= tapBufferCount, !outputBuffers.isEmpty else {
            throw AudioHALError(operation: "aggregate stream layout", status: kAudioHardwareBadStreamError)
        }
        let formats = try AudioHAL.streamFormats(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        guard formats.allSatisfy(AudioHAL.isFloat32) else {
            throw AudioHALError(operation: "output format check", status: kAudioHardwareUnsupportedOperationError)
        }

        let tapBufferStart = inputBuffers.count - tapBufferCount
        let gainState = gainState
        try AudioHAL.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            AudioProcessTap.render(input: input, output: output, tapBufferStart: tapBufferStart, gain: gainState)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        try AudioHAL.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        isRunning = true
    }

    private func log(_ status: OSStatus, _ operation: String) {
        guard status != noErr else { return }
        logger.error("\(operation, privacy: .public) failed (\(AudioHAL.fourCC(status), privacy: .public))")
    }

    // MARK: Real-time rendering

    /// Copies the tap's channels to the output channels with the gain applied,
    /// ramping from the previous cycle's gain to avoid zipper noise. Extra output
    /// channels are zeroed; a mono output gets the L/R average.
    /// Runs on the HAL IO thread: no allocation, locks or ObjC messaging.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               tapBufferStart: Int,
                               gain: TapGain) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        let startGain = gain.rendered.pointee
        let endGain = gain.value
        gain.rendered.pointee = endGain

        var tapChannels = 0
        var index = tapBufferStart
        while index < inputs.count {
            tapChannels += Int(inputs[index].mNumberChannels)
            index += 1
        }
        // Index loops only: in unoptimized builds `for-in` over a range or a buffer list allocates
        // an iterator on every cycle, which the real-time thread must never do.
        var outputChannels = 0
        var outputIndex = 0
        while outputIndex < outputs.count {
            outputChannels += Int(outputs[outputIndex].mNumberChannels)
            outputIndex += 1
        }
        let downmix = outputChannels == 1 && tapChannels >= 2

        var firstChannel = 0
        outputIndex = 0
        while outputIndex < outputs.count {
            let buffer = outputs[outputIndex]
            outputIndex += 1
            let channels = Int(buffer.mNumberChannels)
            let bufferFirstChannel = firstChannel
            firstChannel += channels
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let step = frames > 0 ? (endGain - startGain) / Float(frames) : 0

            var channel = 0
            while channel < channels {
                defer { channel += 1 }
                let destination = data + channel
                var written = 0
                if downmix,
                   let left = source(inputs, tapBufferStart, channel: 0),
                   let right = source(inputs, tapBufferStart, channel: 1) {
                    let count = min(frames, left.frames, right.frames)
                    while written < count {
                        let sample = (left.data[written * left.stride] + right.data[written * right.stride]) * 0.5
                        destination[written * channels] = sample * (startGain + step * Float(written + 1))
                        written += 1
                    }
                } else if let from = source(inputs, tapBufferStart, channel: bufferFirstChannel + channel) {
                    let count = min(frames, from.frames)
                    while written < count {
                        destination[written * channels] = from.data[written * from.stride] * (startGain + step * Float(written + 1))
                        written += 1
                    }
                }
                while written < frames {
                    destination[written * channels] = 0
                    written += 1
                }
            }
        }
    }

    /// Locates the tap's `channel`-th channel among the input buffers.
    @inline(__always)
    private static func source(_ inputs: UnsafeMutableAudioBufferListPointer, _ start: Int,
                               channel: Int) -> (data: UnsafePointer<Float>, stride: Int, frames: Int)? {
        var remaining = channel
        var index = start
        while index < inputs.count {
            let buffer = inputs[index]
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (UnsafePointer(data + remaining), channels, frames)
            }
            remaining -= channels
            index += 1
        }
        return nil
    }
}
