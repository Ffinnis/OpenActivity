//
//  AppGrouper.swift
//  OpenActivity
//
//  Adds every process to the app that launched it: Chrome's helpers to Chrome, a shell and
//  everything it runs to Terminal, WebKit's content processes to Safari.
//

import Foundation

final class AppGrouper {
    struct BundleInfo {
        var id: String
        var name: String
        var path: String
        var identifier: String?
        var isSystem: Bool
    }

    static let systemGroupID = "com.openactivity.macos"

    private var bundles: [String: BundleInfo] = [:]

    func group(_ processes: [ProcessSample]) -> [AppGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // Collect first and build each group once: AppGroup re-totals itself whenever its processes change.
        var members: [String: (owner: BundleInfo, processes: [ProcessSample])] = [:]
        for process in processes {
            let owner = owner(of: process, byPID: byPID)
            members[owner.id, default: (owner, [])].processes.append(process)
        }
        return members.values.map { owner, processes in
            AppGroup(
                id: owner.id,
                name: owner.name,
                bundlePath: owner.path.isEmpty ? nil : owner.path,
                bundleIdentifier: owner.identifier,
                isSystem: owner.isSystem,
                processes: processes
            )
        }
    }

    private func owner(of process: ProcessSample, byPID: [Int32: ProcessSample]) -> BundleInfo {
        // Prefer the responsible process, then walk up the parents until something lives in an app bundle.
        var candidates: [ProcessSample] = [process]
        if process.responsiblePID != process.pid, let responsible = byPID[process.responsiblePID] {
            candidates.insert(responsible, at: 0)
        }
        for candidate in candidates {
            if let path = candidate.path, let info = bundle(containing: path) { return info }
        }
        var current = process
        var hops = 0
        while current.ppid > 1, hops < 16, let parent = byPID[current.ppid] {
            if let path = parent.path, let info = bundle(containing: path) { return info }
            current = parent
            hops += 1
        }

        if Self.isSystemProcess(process) {
            return BundleInfo(id: Self.systemGroupID, name: "macOS", path: "", identifier: nil, isSystem: true)
        }
        return BundleInfo(id: "exec:" + process.name, name: process.name, path: process.path ?? "", identifier: nil, isSystem: false)
    }

    /// The outermost `.app` bundle in the path, so nested helper apps count toward their parent.
    private func bundle(containing path: String) -> BundleInfo? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else {
            return nil
        }
        let bundlePath = String(path[..<range.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = "/" + bundlePath
        if let cached = bundles[fullPath] { return cached }

        let bundle = Bundle(path: fullPath)
        let info = bundle?.infoDictionary ?? [:]
        let identifier = bundle?.bundleIdentifier
        let fileName = ((fullPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = FileManager.default.displayName(atPath: fullPath)
            .replacingOccurrences(of: ".app", with: "")
        let isAgent = (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1"
            || (info["LSBackgroundOnly"] as? Bool) == true
        let isSystem = (fullPath.hasPrefix("/System/Library/") || fullPath.hasPrefix("/Library/Apple/")) && isAgent

        let result = BundleInfo(
            id: identifier ?? fullPath,
            name: name.isEmpty ? fileName : name,
            path: fullPath,
            identifier: identifier,
            isSystem: isSystem
        )
        bundles[fullPath] = result
        return result
    }

    /// Apple's own processes, judged by where the executable lives. The owner only decides when the
    /// path is unknown, so third-party daemons running as root (VPNs, Docker helpers) keep their names.
    private static func isSystemProcess(_ process: ProcessSample) -> Bool {
        if process.pid == 0 { return true }
        guard let path = process.path else { return process.uid < 500 }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/db/",
                "/Library/Developer/CommandLineTools/"]
            .contains { path.hasPrefix($0) }
            || path.hasPrefix("/usr/bin/") && process.ppid == 1
    }
}

// MARK: - Dev servers

enum DevRuntime {
    /// The runtime behind a process, or nil if it does not look like development tooling.
    static func detect(name: String, path: String?) -> String? {
        let lower = name.lowercased()
        switch lower {
        case "node", "nodejs", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node": return "node"
        case "bun": return "bun"
        case "deno": return "deno"
        case "ruby", "rails", "puma", "bundle", "rackup": return "ruby"
        case "java": return "java"
        case "php", "php-fpm": return "php"
        case "dotnet": return "dotnet"
        case "beam.smp", "elixir", "mix", "iex": return "elixir"
        case "go", "air": return "go"
        case "uvicorn", "gunicorn", "flask", "django-admin", "jupyter", "jupyter-lab", "jupyter-notebook": return "python"
        default: break
        }
        if lower.hasPrefix("python") { return "python" }
        guard let path else { return nil }
        if path.contains("/go-build") || path.contains("/go/bin/") { return "go" }
        if path.contains("/target/debug/") || path.contains("/target/release/") { return "rust" }
        if path.contains("/.venv/bin/") || path.contains("/venv/bin/") { return "python" }
        return nil
    }
}

final class ProjectDetector {
    private static let markers = [
        "package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml", "Gemfile",
        "composer.json", "mix.exs", "pom.xml", "build.gradle", "build.gradle.kts", "deno.json", "Package.swift"
    ]

    private var rootCache: [String: (root: String?, package: String?)] = [:]
    private var commandLines: [Int32: (start: Date?, name: String, text: String)] = [:]
    /// Last time each process used more than a trace of CPU, with the process start time to catch pid reuse.
    private var lastActive: [Int32: (start: Date?, date: Date)] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Processes below this share of one core count as idle.
    var idleThreshold: Double = 1.0
    /// A process has to be quiet this long before it is called idle.
    var idleAfter: TimeInterval = 10 * 60

    func projects(from processes: [ProcessSample], now: Date = Date()) -> [DevProject] {
        var projects: [String: DevProject] = [:]
        var alive = Set<Int32>()

        for process in processes {
            guard let directory = process.workingDirectory,
                  directory.hasPrefix(home + "/"),
                  !Self.isEditorTooling(process.path) else { continue }
            let runtime = DevRuntime.detect(name: process.name, path: process.path)
            guard runtime != nil || !process.listeningPorts.isEmpty else { continue }
            guard let location = locate(directory) else { continue }
            alive.insert(process.pid)

            if let entry = lastActive[process.pid], entry.start != process.startTime {
                lastActive[process.pid] = nil
            }
            if lastActive[process.pid] == nil, let start = process.startTime,
               now.timeIntervalSince(start) > idleAfter,
               process.cpuTime / now.timeIntervalSince(start) * 100 < idleThreshold / 2 {
                // Barely touched the CPU in its whole life: treat it as quiet since launch.
                lastActive[process.pid] = (start, start)
            }
            if process.cpuPercent >= idleThreshold || lastActive[process.pid] == nil {
                lastActive[process.pid] = (process.startTime, now)
            }
            let quietSince = lastActive[process.pid]?.date ?? now
            let idleSince = now.timeIntervalSince(quietSince) >= idleAfter ? quietSince : nil

            let dev = DevProcess(
                pid: process.pid,
                name: location.package ?? (location.root as NSString).lastPathComponent,
                runtime: runtime ?? "other",
                ports: process.listeningPorts,
                memory: process.memory,
                cpuPercent: process.cpuPercent,
                startTime: process.startTime,
                idleSince: idleSince,
                commandLine: commandLine(for: process)
            )
            projects[location.root, default: DevProject(
                name: (location.root as NSString).lastPathComponent,
                path: location.root,
                processes: []
            )].processes.append(dev)
        }

        lastActive = lastActive.filter { alive.contains($0.key) }
        commandLines = commandLines.filter { alive.contains($0.key) }
        return projects.values
            // Watchers and workers only count alongside something that serves a port.
            .filter { $0.processes.contains { !$0.ports.isEmpty } }
            .map { project in
                var project = project
                project.processes.sort { ($0.ports.isEmpty ? 1 : 0, $1.memory) < ($1.ports.isEmpty ? 1 : 0, $0.memory) }
                return project
            }
            .sorted { $0.memory > $1.memory }
    }

    /// App helpers and editor extensions (language servers and the like) are not dev servers.
    private static func isEditorTooling(_ path: String?) -> Bool {
        guard let path else { return false }
        // macOS runs every framework Python (Xcode's /usr/bin/python3, Homebrew, venvs made from
        // them) from inside a Python.app bundle; that is the interpreter, not an app helper.
        if path.hasSuffix("/Python.app/Contents/MacOS/Python") { return false }
        return path.contains(".app/Contents/") || path.contains("/extensions/") || path.contains("/.vscode") || path.contains("/.cursor")
    }

    /// The outermost project root (a git checkout or the topmost folder with a manifest) and the
    /// nearest package inside it, so a monorepo shows as one project with named parts.
    private func locate(_ directory: String) -> (root: String, package: String?)? {
        if let cached = rootCache[directory] {
            return cached.root.map { ($0, cached.package) }
        }
        let fileManager = FileManager.default
        var current = directory
        var nearestPackage: String?
        var root: String?
        while current.hasPrefix(home + "/") {
            if nearestPackage == nil, Self.markers.contains(where: { fileManager.fileExists(atPath: current + "/" + $0) }) {
                nearestPackage = current
            }
            if fileManager.fileExists(atPath: current + "/.git") {
                root = current
                break
            }
            current = (current as NSString).deletingLastPathComponent
        }
        let resolvedRoot = root ?? nearestPackage
        var packageName: String?
        if let nearestPackage, nearestPackage != resolvedRoot {
            packageName = Self.packageName(at: nearestPackage) ?? (nearestPackage as NSString).lastPathComponent
        } else if let resolvedRoot {
            packageName = Self.packageName(at: resolvedRoot)
        }
        if rootCache.count > 2000 { rootCache.removeAll() }
        rootCache[directory] = (resolvedRoot, packageName)
        return resolvedRoot.map { ($0, packageName) }
    }

    private static func packageName(at directory: String) -> String? {
        guard let data = FileManager.default.contents(atPath: directory + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else { return nil }
        return name.split(separator: "/").last.map(String.init)
    }

    private func commandLine(for process: ProcessSample) -> String {
        if let cached = commandLines[process.pid], cached.start == process.startTime, cached.name == process.name { return cached.text }
        let arguments = ProcessSampler.commandLine(pid: process.pid)
        let home = self.home
        let text = arguments
            .map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
            .joined(separator: " ")
        commandLines[process.pid] = (process.startTime, process.name, text)
        return text
    }
}
