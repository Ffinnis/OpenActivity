//
//  ProjectsViewController.swift
//  OpenActivity
//
//  Dev servers grouped by the project folder they run in, with their ports and how long they
//  have been idle. Stopping anything always asks first.
//

import AppKit

final class ProjectsViewController: NSViewController, LivePage, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class ProjectNode {
        var project: DevProject
        init(_ project: DevProject) { self.project = project }
    }

    private final class ProcessNode {
        var process: DevProcess
        init(_ process: DevProcess) { self.process = process }
    }

    private let outlineView = NSOutlineView()
    private let summaryTitle = NSTextField.label("", size: 20, weight: .bold)
    private let summaryDetail = NSTextField.label("", size: 12, color: .secondaryLabelColor)
    private let banner = CardView(frame: .zero)
    private let bannerTitle = NSTextField.label("", size: 13, weight: .semibold)
    private let bannerDetail = NSTextField.label("", size: 12, color: .secondaryLabelColor)
    private let toast = PillView("", color: .systemGreen, monospaced: false)
    private let emptyState = NSTextField.wrapping(
        "No dev servers are running. When you start one from a project folder (node, python, ruby, go, bun and others), it shows up here with its ports.",
        size: 13, color: .secondaryLabelColor
    )

    private var projectNodes: [String: ProjectNode] = [:]
    private var processNodes: [Int32: ProcessNode] = [:]
    private var visible: [ProjectNode] = []
    private var projects: [DevProject] = []
    private var searchText = ""
    private var idleProcesses: [DevProcess] = []
    private var expandedOnce = Set<String>()

    override func loadView() {
        let root = NSView()

        let header = NSStackView.vertical([summaryTitle, summaryDetail], spacing: 2)

        let moon = NSImageView(image: NSImage.symbol("moon.zzz.fill", size: 18, color: .systemIndigo) ?? NSImage())
        let stopAll = NSButton(title: "Stop Idle…", target: self, action: #selector(stopIdle))
        stopAll.bezelStyle = .rounded
        let bannerRow = NSStackView.horizontal([moon, NSStackView.vertical([bannerTitle, bannerDetail], spacing: 2), NSView.spacer(), stopAll], spacing: 12)
        banner.content.addArrangedSubview(bannerRow)
        bannerRow.widthAnchor.constraint(equalTo: banner.content.widthAnchor).isActive = true
        banner.contentInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        toast.isHidden = true

        let top = NSStackView.vertical([header, banner, toast], spacing: 12)
        top.translatesAutoresizingMaskIntoConstraints = false
        // NSStackView hugs its content through its own API, not content hugging.
        top.setHuggingPriority(.required, for: .vertical)
        banner.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true

        setUpOutline()
        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(top)
        root.addSubview(scroll)
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.pagePadding),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.pagePadding),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            emptyState.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 30),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.pagePadding),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        view = root
    }

    private func setUpOutline() {
        outlineView.style = .inset
        outlineView.headerView = nil
        outlineView.rowHeight = 34
        outlineView.indentationPerLevel = 14
        outlineView.selectionHighlightStyle = .regular
        outlineView.dataSource = self
        outlineView.delegate = self
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }

    // MARK: - Updates

    func update(with snapshot: SystemSnapshot) {
        projects = snapshot.projects
        let processCount = projects.reduce(0) { $0 + $1.processes.count }
        let memory = projects.reduce(0) { $0 + $1.memory }
        let ports = projects.reduce(0) { $0 + $1.ports.count }
        summaryTitle.set(projects.isEmpty ? "Projects" : projects.count == 1 ? "1 project" : "\(projects.count) projects")
        summaryDetail.set(projects.isEmpty ? "Dev servers and the ports they hold, grouped by project folder"
                          : "\(Format.processes(processCount)) · \(Format.memory(memory)) · \(ports == 1 ? "1 port" : "\(ports) ports") open")

        idleProcesses = projects.flatMap(\.processes).filter { $0.idleSince != nil && !$0.ports.isEmpty }
        banner.isHidden = idleProcesses.isEmpty
        if !idleProcesses.isEmpty {
            let freed = idleProcesses.reduce(0) { $0 + $1.memory }
            let portList = idleProcesses.flatMap(\.ports).sorted().map(String.init).joined(separator: ", ")
            bannerTitle.set(idleProcesses.count == 1 ? "1 dev server is running but not doing anything" : "\(idleProcesses.count) dev servers are running but not doing anything")
            bannerDetail.set("Stopping them frees \(Format.memory(freed)) and ports \(portList).")
        }
        emptyState.isHidden = !projects.isEmpty
        rebuild()
    }

    func applySearch(_ text: String) {
        searchText = text.lowercased().trimmingCharacters(in: .whitespaces)
        rebuild()
    }

    private func rebuild() {
        var nextProjects: [String: ProjectNode] = [:]
        var nextProcesses: [Int32: ProcessNode] = [:]
        var result: [ProjectNode] = []
        for project in projects {
            var project = project
            if !searchText.isEmpty && !project.name.lowercased().contains(searchText) {
                project.processes = project.processes.filter {
                    $0.name.lowercased().contains(searchText) || $0.ports.contains { String($0) == searchText }
                }
                if project.processes.isEmpty { continue }
            }
            let node = projectNodes[project.id] ?? ProjectNode(project)
            node.project = project
            nextProjects[project.id] = node
            for process in project.processes {
                let child = processNodes[process.pid] ?? ProcessNode(process)
                child.process = process
                nextProcesses[process.pid] = child
            }
            result.append(node)
        }
        projectNodes = nextProjects
        processNodes = nextProcesses
        visible = result
        outlineView.reloadData()
        for node in visible where !expandedOnce.contains(node.project.id) {
            expandedOnce.insert(node.project.id)
            outlineView.expandItem(node)
        }
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return visible.count }
        return (item as? ProjectNode)?.project.processes.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return visible[index] }
        let project = (item as! ProjectNode).project
        return processNodes[project.processes[index].pid]!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ProjectNode
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is ProjectNode ? 40 : 36
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? ProjectNode {
            let cell = outlineView.makeView(withIdentifier: ProjectCell.identifier, owner: nil) as? ProjectCell ?? ProjectCell()
            cell.configure(node.project)
            cell.onStop = { [weak self] in
                guard let self else { return }
                ProcessControl.stop(node.project.processes, title: "Stop everything in \(node.project.name)?", window: self.view.window) { freed, ports in
                    self.showToast("\(node.project.name) stopped", freed: freed, ports: ports)
                }
            }
            cell.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.project.path)]) }
            return cell
        }
        guard let node = item as? ProcessNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: DevProcessCell.identifier, owner: nil) as? DevProcessCell ?? DevProcessCell()
        cell.configure(node.process)
        cell.onStop = { [weak self] in
            guard let self else { return }
            let process = node.process
            ProcessControl.stop([process], title: "Stop \(process.name)?", window: self.view.window) { freed, ports in
                self.showToast("\(process.name) stopped", freed: freed, ports: ports)
            }
        }
        return cell
    }

    @objc private func stopIdle() {
        let idle = idleProcesses
        let title = idle.count == 1 ? "Stop the idle dev server?" : "Stop \(idle.count) idle dev servers?"
        ProcessControl.stop(idle, title: title, window: view.window) { [weak self] freed, ports in
            self?.showToast(idle.count == 1 ? "Idle server stopped" : "\(idle.count) idle servers stopped", freed: freed, ports: ports)
        }
    }

    private func showToast(_ text: String, freed: UInt64, ports: [UInt16]) {
        var message = "\(text). \(Format.memory(freed)) freed"
        if !ports.isEmpty { message += ", " + (ports.count == 1 ? "port " : "ports ") + ports.map(String.init).joined(separator: ", ") + " available" }
        toast.label.set(message + ".")
        toast.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.toast.isHidden = true }
    }
}

// MARK: - Cells

private final class ProjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ProjectCell")
    var onStop: (() -> Void)?
    var onReveal: (() -> Void)?
    private let icon = NSImageView(image: NSImage.symbol("folder.fill", size: 15, color: Theme.color(for: .projects)) ?? NSImage())
    private let name = NSTextField.label("", size: 13, weight: .semibold)
    private let detail = NSTextField.caption()
    private let status = PillView("", monospaced: false)
    private let memory = NSTextField.number("", size: 12, weight: .medium)
    private let stop = NSButton(title: "Stop All…", target: nil, action: nil)
    private let reveal = NSButton()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        // Same width on project and process rows keeps the memory column aligned.
        stop.widthAnchor.constraint(equalToConstant: 82).isActive = true
        stop.target = self
        stop.action = #selector(stopTapped)
        reveal.image = NSImage.symbol("arrow.up.forward.square", size: 12, color: .secondaryLabelColor)
        reveal.isBordered = false
        reveal.target = self
        reveal.action = #selector(revealTapped)
        reveal.toolTip = "Show in Finder"
        memory.alignment = .right
        memory.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let text = NSStackView.vertical([NSStackView.horizontal([name, reveal], spacing: 4), detail], spacing: 1)
        let stack = NSStackView.horizontal([icon, text, NSView.spacer(), status, memory, stop], spacing: 10)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ project: DevProject) {
        name.set(project.name)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = project.path.hasPrefix(home) ? "~" + project.path.dropFirst(home.count) : project.path
        detail.set("\(Format.processes(project.processes.count)) · \(path)")
        status.label.set(project.isIdle ? "idle" : "working")
        status.color = project.isIdle ? .systemIndigo : .systemGreen
        memory.set(Format.memory(project.memory))
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func revealTapped() { onReveal?() }
}

private final class DevProcessCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("DevProcessCell")
    var onStop: (() -> Void)?
    private let runtime = PillView("", monospaced: false)
    private let name = NSTextField.label("", size: 12, weight: .medium)
    private let state = NSTextField.label("", size: 11, color: .secondaryLabelColor)
    private let ports = NSStackView.horizontal(spacing: 4)
    private let memory = NSTextField.number("", size: 12)
    private let stop = NSButton(title: "Stop…", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        // Same width on project and process rows keeps the memory column aligned.
        stop.widthAnchor.constraint(equalToConstant: 82).isActive = true
        stop.target = self
        stop.action = #selector(stopTapped)
        memory.alignment = .right
        memory.widthAnchor.constraint(equalToConstant: 80).isActive = true
        runtime.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let text = NSStackView.vertical([name, state], spacing: 1)
        let stack = NSStackView.horizontal([runtime, text, NSView.spacer(), ports, memory, stop], spacing: 10)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ process: DevProcess) {
        runtime.label.set(process.runtime)
        runtime.color = Self.color(for: process.runtime)
        name.set(process.name)
        name.toolTip = process.commandLine
        state.set(Self.describe(process))
        let wanted = process.ports.map(String.init)
        let shown = ports.arrangedSubviews.compactMap { ($0 as? PillView)?.label.stringValue }
        if wanted != shown {
            ports.removeAllArrangedSubviews()
            for port in wanted { ports.addArrangedSubview(PillView(":" + port, color: .controlAccentColor)) }
        }
        memory.set(Format.memory(process.memory))
    }

    /// "up 3 days, barely used", "idle 45 min", "working · 12% CPU".
    private static func describe(_ process: DevProcess) -> String {
        let now = Date()
        let uptime = process.startTime.map { now.timeIntervalSince($0) } ?? 0
        if let idleSince = process.idleSince {
            let idle = now.timeIntervalSince(idleSince)
            if uptime > 86_400 && idle > uptime * 0.9 { return "up \(Format.span(uptime)), hardly used" }
            return "idle for \(Format.span(idle))"
        }
        var text = "pid \(process.pid)"
        if uptime > 0 { text += " · up \(Format.span(uptime))" }
        if process.cpuPercent >= 1 { text += " · \(Format.cpu(process.cpuPercent)) CPU" }
        return text
    }

    private static func color(for runtime: String) -> NSColor {
        switch runtime {
        case "node", "bun", "deno": return .systemGreen
        case "python": return .systemBlue
        case "ruby": return .systemRed
        case "go": return .systemTeal
        case "java", "rust": return .systemOrange
        case "php", "elixir", "dotnet": return .systemPurple
        default: return .secondaryLabelColor
        }
    }

    @objc private func stopTapped() { onStop?() }
}
