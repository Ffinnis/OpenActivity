//
//  AudioVolumeController.swift
//  OpenActivity
//
//  Per-app volume and mute. Watches Core Audio's process objects, groups
//  helper processes under the app that owns them, and routes attenuated or
//  muted apps through an AudioProcessTap. Settings persist per bundle ID.
//

import AppKit
import CoreAudio
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenActivity", category: "AudioVolume")

/// One row of the per-app volume list. May stand for several Core Audio
/// process objects (an app plus the helpers that play audio on its behalf).
struct AudioApp: Hashable {
    /// PID of the owning app (not necessarily the process producing audio).
    var pid: Int32
    var bundleIdentifier: String?
    var name: String
    /// True while the process is currently sending audio to an output device.
    var isPlaying: Bool
    /// 0...1
    var volume: Float
    var isMuted: Bool
}

/// Main-thread facade for per-app volume. Core Audio work happens on a private
/// serial queue inside `AudioTapEngine`.
final class AudioVolumeController {
    static let shared = AudioVolumeController()

    /// Called on the main thread whenever the list of audio apps or their state
    /// changes. Edits made through `setVolume`/`setMuted` only trigger it when
    /// they change which apps are listed (the caller already knows the value).
    var onChange: (() -> Void)?

    private static let defaultsKey = "audio.volumes"
    /// How long a tap outlives the app's last audible output. Keeping it briefly
    /// avoids a full-volume blip when playback resumes after a short pause,
    /// tearing it down afterwards lets the output device idle.
    private static let idleGrace: TimeInterval = 30

    private let engine = AudioTapEngine()
    private var groups: [pid_t: AudioProcessGroup] = [:]
    private var owners: [AudioObjectID: AudioProcessOwner] = [:]
    private var settings: [SettingKey: VolumeSetting] = [:]
    private var lastPlayed: [pid_t: Date] = [:]
    private var apps: [AudioApp] = []
    private var idleTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        loadSettings()
        engine.onProcessesChange = { [weak self] in self?.update(with: $0) }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.shutdown() }
        engine.start()
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        shutdown()
    }

    // MARK: Public API

    /// Apps that are playing now, plus apps with a non-default volume/mute that
    /// are still running. Sorted playing-first then by name.
    func audioApps() -> [AudioApp] { apps }

    func setVolume(_ volume: Float, for pid: Int32) {
        updateSetting(for: pid) { $0.volume = volume.isFinite ? min(max(volume, 0), 1) : 1 }
    }

    func setMuted(_ muted: Bool, for pid: Int32) {
        updateSetting(for: pid) { $0.isMuted = muted }
    }

    /// Restores every app to full volume, unmuted, and forgets saved settings.
    func resetAll() {
        settings.removeAll()
        saveSettings()
        syncTaps()
        publish(userEdit: false)
    }

    // MARK: Process list

    private func update(with processes: [AudioProcessEntry]) {
        let now = Date()
        var resolved: [AudioObjectID: AudioProcessOwner] = [:]
        var grouped: [pid_t: AudioProcessGroup] = [:]
        for process in processes {
            let owner = owners[process.objectID].flatMap { $0.sourcePID == process.pid ? $0 : nil }
                ?? AudioProcessOwner.resolve(process)
            resolved[process.objectID] = owner
            grouped[owner.pid, default: AudioProcessGroup(owner: owner)].add(process)
        }

        // Remember when each app was last audible, including the moment it stops.
        for (pid, group) in grouped where group.isPlaying || groups[pid]?.isPlaying == true {
            lastPlayed[pid] = now
        }
        lastPlayed = lastPlayed.filter { grouped[$0.key] != nil }
        settings = settings.filter {
            if case .process(let pid) = $0.key { return grouped[pid] != nil }
            return true
        }

        owners = resolved
        groups = grouped
        syncTaps()
        publish(userEdit: false)
    }

    // MARK: Settings

    private func updateSetting(for pid: pid_t, _ change: (inout VolumeSetting) -> Void) {
        let key = settingKey(for: pid)
        var setting = settings[key] ?? VolumeSetting()
        change(&setting)
        settings[key] = setting.isDefault ? nil : setting
        if case .bundle = key { saveSettings() }
        syncTaps()
        publish(userEdit: true)
    }

    private func settingKey(for pid: pid_t) -> SettingKey {
        let bundleID = groups[pid].map { $0.owner.bundleID } ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return bundleID.map(SettingKey.bundle) ?? .process(pid)
    }

    private func setting(for group: AudioProcessGroup) -> VolumeSetting {
        let key = group.owner.bundleID.map(SettingKey.bundle) ?? .process(group.owner.pid)
        return settings[key] ?? VolumeSetting()
    }

    private func loadSettings() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) else { return }
        for (bundleID, value) in stored {
            guard let entry = value as? [String: Any] else { continue }
            let setting = VolumeSetting(
                volume: Float(min(max((entry["volume"] as? Double) ?? 1, 0), 1)),
                isMuted: (entry["muted"] as? Bool) ?? false
            )
            if !setting.isDefault { settings[.bundle(bundleID)] = setting }
        }
    }

    private func saveSettings() {
        var stored: [String: Any] = [:]
        for case let (.bundle(bundleID), setting) in settings {
            stored[bundleID] = ["volume": Double(setting.volume), "muted": setting.isMuted]
        }
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.set(stored, forKey: Self.defaultsKey)
        }
    }

    // MARK: Taps

    /// Tells the engine which apps need a tap: non-default setting and audible
    /// now or within the idle grace period.
    private func syncTaps() {
        let now = Date()
        var specs: [pid_t: AudioTapSpec] = [:]
        var nextExpiry: Date?
        for (pid, group) in groups {
            let setting = setting(for: group)
            guard !setting.isDefault else { continue }
            if !group.isPlaying {
                guard let last = lastPlayed[pid] else { continue }
                let expiry = last.addingTimeInterval(Self.idleGrace)
                guard expiry > now else { continue }
                nextExpiry = min(nextExpiry ?? expiry, expiry)
            }
            specs[pid] = AudioTapSpec(processObjectIDs: group.objectIDs.sorted(), gain: setting.gain,
                                      name: group.owner.name, isPlaying: group.isPlaying)
        }
        engine.apply(specs)

        idleTimer?.invalidate()
        idleTimer = nextExpiry.map { expiry in
            Timer.scheduledTimer(withTimeInterval: max(expiry.timeIntervalSince(now), 0) + 0.1, repeats: false) { [weak self] _ in
                self?.syncTaps()
            }
        }
    }

    private func publish(userEdit: Bool) {
        let updated = groups.values.compactMap { group -> AudioApp? in
            let setting = setting(for: group)
            guard group.isPlaying || !setting.isDefault else { return nil }
            return AudioApp(pid: group.owner.pid, bundleIdentifier: group.owner.bundleID, name: group.owner.name,
                            isPlaying: group.isPlaying, volume: setting.volume, isMuted: setting.isMuted)
        }.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.pid < rhs.pid
            }
        }
        let changed = userEdit ? updated.map(\.pid) != apps.map(\.pid) : updated != apps
        apps = updated
        if changed { onChange?() }
    }

    private func shutdown() {
        idleTimer?.invalidate()
        idleTimer = nil
        engine.shutdown()
    }
}

// MARK: - Model

private enum SettingKey: Hashable {
    case bundle(String)
    /// Apps without a bundle ID; kept in memory only.
    case process(pid_t)
}

private struct VolumeSetting: Equatable {
    var volume: Float = 1
    var isMuted = false

    var isDefault: Bool { volume >= 1 && !isMuted }
    /// Linear amplitude for the tap. Squared so the slider feels perceptually even.
    var gain: Float { isMuted ? 0 : volume * volume }
}

/// A Core Audio process object as read on the engine queue.
private struct AudioProcessEntry {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
}

/// The app a process's audio is attributed to.
private struct AudioProcessOwner {
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// PID of the process object this was resolved for (guards against reuse).
    let sourcePID: pid_t

    /// Helpers (Chrome's "Google Chrome Helper", Safari's WebKit GPU process)
    /// resolve to the app they belong to: first via the outermost `.app` in
    /// their executable path, then, for XPC services, via the responsible PID.
    /// Plain command-line tools stand for themselves.
    static func resolve(_ process: AudioProcessEntry) -> AudioProcessOwner {
        let path = executablePath(of: process.pid)
        let responsible = responsiblePID(of: process.pid)

        if let path, let bundlePath = outermostAppBundle(in: path),
           let app = runningApplication(at: bundlePath, preferring: [responsible, process.pid].compactMap { $0 }) {
            return AudioProcessOwner(app, for: process)
        }
        if let responsible, responsible != process.pid, path?.contains(".xpc/") ?? true,
           let app = NSRunningApplication(processIdentifier: responsible), app.bundleURL != nil {
            return AudioProcessOwner(app, for: process)
        }
        if let app = NSRunningApplication(processIdentifier: process.pid), app.localizedName != nil {
            return AudioProcessOwner(app, for: process)
        }
        let name = path.map { ($0 as NSString).lastPathComponent } ?? process.bundleID ?? "PID \(process.pid)"
        return AudioProcessOwner(pid: process.pid, bundleID: process.bundleID, name: name, sourcePID: process.pid)
    }

    private init(pid: pid_t, bundleID: String?, name: String, sourcePID: pid_t) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.sourcePID = sourcePID
    }

    private init(_ app: NSRunningApplication, for process: AudioProcessEntry) {
        let bundleID = app.bundleIdentifier ?? (app.processIdentifier == process.pid ? process.bundleID : nil)
        let name = app.localizedName
            ?? app.bundleURL.map { $0.deletingPathExtension().lastPathComponent }
            ?? bundleID
            ?? "PID \(app.processIdentifier)"
        self.init(pid: app.processIdentifier, bundleID: bundleID, name: name, sourcePID: process.pid)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func outermostAppBundle(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[...index].joined(separator: "/")
    }

    private static func runningApplication(at bundlePath: String, preferring pids: [pid_t]) -> NSRunningApplication? {
        let target = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().path == target
        }
        return candidates.first { pids.contains($0.processIdentifier) } ?? candidates.first
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        // RTLD_DEFAULT is ((void *)-2) and isn't imported into Swift.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let responsible = responsibleFunction(pid)
        return responsible > 0 ? responsible : nil
    }
}

/// All process objects attributed to one owner.
private struct AudioProcessGroup {
    let owner: AudioProcessOwner
    private(set) var objectIDs: [AudioObjectID] = []
    private(set) var isPlaying = false

    init(owner: AudioProcessOwner) { self.owner = owner }

    mutating func add(_ process: AudioProcessEntry) {
        objectIDs.append(process.objectID)
        isPlaying = isPlaying || process.isPlaying
    }
}

private struct AudioTapSpec {
    var processObjectIDs: [AudioObjectID]
    var gain: Float
    var name: String
    /// New taps are only built while the app is audible: with TapAutoStart,
    /// AudioDeviceStart waits for the tapped processes to produce audio.
    var isPlaying: Bool
}

// MARK: - Engine

/// Owns every Core Audio listener and tap. All state is confined to `queue`;
/// results are delivered to the main thread.
private final class AudioTapEngine {
    /// Invoked on the main thread with the current process objects (own process excluded).
    var onProcessesChange: (([AudioProcessEntry]) -> Void)?

    private static let retryInterval: TimeInterval = 5
    private let queue = DispatchQueue(label: "OpenActivity.AudioVolume", qos: .userInitiated)

    // Queue-confined state.
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processListener: AudioObjectPropertyListenerBlock?
    private var watchedProcesses: Set<AudioObjectID> = []
    private var refreshPending = false
    private var outputDeviceUID: String?
    private var specs: [pid_t: AudioTapSpec] = [:]
    private var taps: [pid_t: AudioProcessTap] = [:]
    private var failures: [pid_t: (spec: AudioTapSpec, deviceUID: String, date: Date)] = [:]
    private var permissionRequested = false
    private var loggedDenial = false
    private var isShutDown = false

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    /// Per-process properties to observe. The HAL (as of macOS 26) doesn't notify
    /// IsRunningOutput changes, but does notify IsRunning, so watch both and
    /// re-read IsRunningOutput on refresh.
    private static let processAddresses = [
        AudioHAL.address(kAudioProcessPropertyIsRunningOutput),
        AudioHAL.address(kAudioProcessPropertyIsRunning),
    ]

    func start() {
        queue.async { [self] in
            processListener = { [weak self] _, _ in self?.scheduleRefresh() }
            addSystemListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.scheduleRefresh() }
            addSystemListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputDeviceChanged() }
            readOutputDevice()
            refreshProcesses()
        }
    }

    /// Replaces the desired set of taps, keyed by owner PID.
    func apply(_ specs: [pid_t: AudioTapSpec]) {
        queue.async { [self] in
            guard !isShutDown else { return }
            self.specs = specs
            reconcile()
        }
    }

    /// Destroys all taps and listeners. Waits briefly so it can run at termination.
    func shutdown() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            defer { done.signal() }
            guard !isShutDown else { return }
            isShutDown = true
            specs.removeAll()
            taps.values.forEach { $0.invalidate() }
            taps.removeAll()
            for (address, block) in systemListeners {
                var address = address
                _ = AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, queue, block)
            }
            systemListeners.removeAll()
            watchedProcesses.forEach(unwatch)
            watchedProcesses.removeAll()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            logger.error("Timed out tearing down audio taps")
        }
    }

    // MARK: Listeners

    private func addSystemListener(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = AudioHAL.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, queue, block)
        if status == noErr {
            systemListeners.append((address, block))
        } else {
            logger.error("Listening for '\(AudioHAL.fourCC(selector), privacy: .public)' failed (\(AudioHAL.fourCC(status), privacy: .public))")
        }
    }

    private func watch(_ process: AudioObjectID) -> Bool {
        guard let processListener else { return false }
        var added = false
        for var address in Self.processAddresses {
            added = AudioObjectAddPropertyListenerBlock(process, &address, queue, processListener) == noErr || added
        }
        return added
    }

    private func unwatch(_ process: AudioObjectID) {
        guard let processListener else { return }
        for var address in Self.processAddresses {
            // Fails harmlessly when the process object is already gone.
            _ = AudioObjectRemovePropertyListenerBlock(process, &address, queue, processListener)
        }
    }

    /// Coalesces bursts of HAL notifications (e.g. a browser spinning up helpers).
    private func scheduleRefresh() {
        guard !refreshPending, !isShutDown else { return }
        refreshPending = true
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            refreshPending = false
            refreshProcesses()
        }
    }

    private func refreshProcesses() {
        guard !isShutDown else { return }
        let ids: [AudioObjectID]
        do {
            ids = try AudioHAL.objectIDs(Self.systemObject, kAudioHardwarePropertyProcessObjectList)
        } catch {
            logger.error("Reading process objects: \(String(describing: error), privacy: .public)")
            return
        }

        let current = Set(ids)
        for id in current.subtracting(watchedProcesses) where watch(id) { watchedProcesses.insert(id) }
        for id in watchedProcesses.subtracting(current) {
            unwatch(id)
            watchedProcesses.remove(id)
        }

        let ownPID = getpid()
        let entries = ids.compactMap { id -> AudioProcessEntry? in
            guard let pid = try? AudioHAL.value(id, kAudioProcessPropertyPID, initial: pid_t(-1)),
                  pid > 0, pid != ownPID else { return nil }
            let bundleID = (try? AudioHAL.string(id, kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
            let running = (try? AudioHAL.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcessEntry(objectID: id, pid: pid, bundleID: bundleID, isPlaying: running != 0)
        }
        DispatchQueue.main.async { [weak self] in self?.onProcessesChange?(entries) }
    }

    private func outputDeviceChanged() {
        readOutputDevice()
        reconcile()
    }

    private func readOutputDevice() {
        do {
            outputDeviceUID = try AudioHAL.defaultOutputDevice().uid
        } catch {
            outputDeviceUID = nil
            logger.error("Reading default output device: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Taps

    /// Brings `taps` in line with `specs` and the current output device.
    private func reconcile() {
        guard !isShutDown else { return }
        for owner in taps.keys where specs[owner] == nil {
            taps.removeValue(forKey: owner)?.invalidate()
        }
        failures = failures.filter { specs[$0.key] != nil }

        guard let deviceUID = outputDeviceUID else {
            taps.values.forEach { $0.invalidate() }
            taps.removeAll()
            return
        }

        for (owner, spec) in specs {
            if let tap = taps[owner], tap.outputDeviceUID == deviceUID,
               tap.processObjectIDs == spec.processObjectIDs || tap.updateProcesses(spec.processObjectIDs) {
                tap.gain = spec.gain
            } else if spec.isPlaying {
                install(spec, for: owner, on: deviceUID)
            } else {
                taps.removeValue(forKey: owner)?.invalidate()
            }
        }
    }

    /// Builds a new tap for `owner`, replacing any existing one only after the
    /// new one runs (so a muted app doesn't blip to full volume). On failure the
    /// app is left untouched.
    private func install(_ spec: AudioTapSpec, for owner: pid_t, on deviceUID: String) {
        let previous = taps.removeValue(forKey: owner)
        defer { previous?.invalidate() }

        if let failure = failures[owner], failure.deviceUID == deviceUID,
           failure.spec.processObjectIDs == spec.processObjectIDs,
           Date().timeIntervalSince(failure.date) < Self.retryInterval {
            return
        }
        guard mayCreateTaps() else { return }

        do {
            taps[owner] = try AudioProcessTap(processObjectIDs: spec.processObjectIDs, outputDeviceUID: deviceUID,
                                              gain: spec.gain, name: spec.name)
            failures[owner] = nil
        } catch {
            failures[owner] = (spec, deviceUID, Date())
            logger.error("Tapping \(spec.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            // Failures cluster around route changes; nothing else would trigger another attempt.
            queue.asyncAfter(deadline: .now() + Self.retryInterval + 0.5) { [weak self] in self?.reconcile() }
        }
    }

    /// Checks the audio-capture permission, prompting once when undetermined.
    private func mayCreateTaps() -> Bool {
        switch AudioCapturePermission.status {
        case .authorized, .unavailable:
            loggedDenial = false
            return true
        case .denied:
            if !loggedDenial {
                loggedDenial = true
                logger.error("Audio capture permission denied; per-app volume is inactive")
            }
            return false
        case .undetermined:
            guard !permissionRequested else { return false }
            permissionRequested = true
            AudioCapturePermission.request { [weak self] granted in
                guard let self else { return }
                queue.async {
                    self.permissionRequested = false
                    if granted { self.reconcile() } else { logger.error("Audio capture permission not granted") }
                }
            }
            return false
        }
    }
}
