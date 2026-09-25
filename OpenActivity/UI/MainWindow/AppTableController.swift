//
//  AppTableController.swift
//  OpenActivity
//
//  One row per app, expandable to its processes. Columns depend on the metric being shown.
//

import AppKit

final class AppNode {
    var app: AppGroup
    var children: [ProcessNode] = []
    init(app: AppGroup) { self.app = app }
}

final class ProcessNode {
    var process: ProcessSample
    weak var parent: AppNode?
    init(process: ProcessSample, parent: AppNode) {
        self.process = process
        self.parent = parent
    }
}

final class AppTableController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let ascendingByDefault: Bool
        let app: (AppGroup) -> Double
        let process: (ProcessSample) -> Double
        let text: (Double) -> String

        init(_ id: String, _ title: String, width: CGFloat = 90, ascending: Bool = false,
             app: @escaping (AppGroup) -> Double, process: @escaping (ProcessSample) -> Double, text: @escaping (Double) -> String) {
            self.id = id
            self.title = title
            self.width = width
            self.ascendingByDefault = ascending
            self.app = app
            self.process = process
            self.text = text
        }
    }

    let metric: Metric
    let outlineView = NSOutlineView()
    let scrollView = NSScrollView()

    private var columns: [Column] = []
    private var nodes: [String: AppNode] = [:]
    private var processNodes: [Int32: ProcessNode] = [:]
    private var visible: [AppNode] = []
    private var snapshotApps: [AppGroup] = []
    private var sortKey: String
    private var ascending = false
    private var searchText = ""
    private var memoryTotal: Double = 1

    init(metric: Metric) {
        self.metric = metric
        sortKey = metric.rawValue
        super.init()
        columns = Self.columns(for: metric)
        sortKey = columns.first?.id ?? "name"
        setUpOutline()
    }

    // MARK: - Columns

    private static func columns(for metric: Metric) -> [Column] {
        let processes = Column("processes", "Processes", width: 80,
                               app: { Double($0.processes.count) }, process: { _ in -1 },
                               text: { $0 < 0 ? "" : Format.number(Int($0)) })
        switch metric {
        case .cpu:
            return [
                Column("cpu", "% CPU", app: { $0.cpuPercent }, process: { $0.cpuPercent }, text: Format.cpu),
                Column("cpuTime", "CPU Time", width: 90, app: { $0.processes.reduce(0) { $0 + $1.cpuTime } }, process: { $0.cpuTime }, text: Format.cpuTime),
                Column("threads", "Threads", width: 70, app: { Double($0.processes.reduce(0) { $0 + $1.threads }) }, process: { Double($0.threads) }, text: { Format.number(Int($0)) }),
                processes,
            ]
        case .memory:
            return [
                Column("memory", "Memory", width: 100, app: { Double($0.memory) }, process: { Double($0.memory) }, text: { Format.memory($0) }),
                Column("share", "Share", width: 110, app: { Double($0.memory) }, process: { Double($0.memory) }, text: { _ in "" }),
                processes,
            ]
        case .disk:
            return [
                Column("diskWrite", "Writing", width: 100, app: { $0.diskWriteRate }, process: { $0.diskWriteRate }, text: Format.rate),
                Column("diskRead", "Reading", width: 100, app: { $0.diskReadRate }, process: { $0.diskReadRate }, text: Format.rate),
                processes,
            ]
        case .network:
            return [
                Column("netIn", "Downloading", width: 110, app: { $0.netInRate }, process: { $0.netInRate }, text: Format.rate),
                Column("netOut", "Uploading", width: 100, app: { $0.netOutRate }, process: { $0.netOutRate }, text: Format.rate),
                processes,
            ]
        case .gpu:
            return [
                Column("gpu", "% GPU", app: { $0.gpuPercent }, process: { $0.gpuPercent }, text: { String(format: "%.1f%%", $0) }),
                Column("memory", "Memory", width: 100, app: { Double($0.memory) }, process: { Double($0.memory) }, text: { Format.memory($0) }),
                processes,
            ]
        default:
            return [
                Column("power", "Power", app: { $0.power }, process: { $0.power }, text: Format.watts),
                Column("cpu", "% CPU", app: { $0.cpuPercent }, process: { $0.cpuPercent }, text: Format.cpu),
                processes,
            ]
        }
    }

    private func setUpOutline() {
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.rowHeight = 26
        outlineView.intercellSpacing = NSSize(width: 10, height: 2)
        outlineView.allowsMultipleSelection = false
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 14
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))

        let name = NSTableColumn(identifier: .init("name"))
        name.title = "App"
        name.minWidth = 200
        name.width = 320
        name.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        outlineView.addTableColumn(name)
        outlineView.outlineTableColumn = name

        for column in columns {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.headerCell.alignment = column.id == "share" ? .left : .right
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: column.ascendingByDefault)
            outlineView.addTableColumn(tableColumn)
        }
        outlineView.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: false)]

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Data

    func update(apps: [AppGroup], memoryTotal: UInt64) {
        self.memoryTotal = Double(max(1, memoryTotal))
        snapshotApps = apps
        rebuild()
    }

    func setSearch(_ text: String) {
        let next = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard next != searchText else { return }
        searchText = next
        // Close what the previous search opened, so clearing a search restores the list.
        for node in searchExpanded { outlineView.collapseItem(node) }
        searchExpanded.removeAll()
        rebuild()
        // Open apps that match only by a process name, once per search rather than every sample.
        if !searchText.isEmpty {
            for node in visible where !node.app.name.lowercased().contains(searchText) && !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
                searchExpanded.append(node)
            }
        }
    }

    /// Apps expanded by the current search rather than by the user.
    private var searchExpanded: [AppNode] = []

    /// Reloads while keeping the selected item (not the row number) selected.
    private func reloadKeepingSelection() {
        let selected = outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as AnyObject? : nil
        outlineView.reloadData()
        guard let selected else { return }
        let row = outlineView.row(forItem: selected)
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    private func rebuild() {
        let showSystem = Preferences.shared.showSystemProcesses
        var nextNodes: [String: AppNode] = [:]
        var nextProcessNodes: [Int32: ProcessNode] = [:]
        var result: [AppNode] = []

        for app in snapshotApps {
            if app.isSystem && !showSystem { continue }
            var processes = app.processes
            if !searchText.isEmpty && !app.name.lowercased().contains(searchText) {
                processes = processes.filter { $0.name.lowercased().contains(searchText) || String($0.pid) == searchText }
                if processes.isEmpty { continue }
            }
            let node = nodes[app.id] ?? AppNode(app: app)
            node.app = app
            node.children = processes.map { process in
                let child = processNodes[process.pid] ?? ProcessNode(process: process, parent: node)
                child.process = process
                child.parent = node
                nextProcessNodes[process.pid] = child
                return child
            }
            nextNodes[app.id] = node
            result.append(node)
        }
        nodes = nextNodes
        processNodes = nextProcessNodes
        visible = sort(result)

        let structure = currentStructure()
        if structure == shownStructure {
            refreshVisibleCells()
        } else {
            shownStructure = structure
            reloadKeepingSelection()
        }
    }

    /// Row order, expansion and child counts; when unchanged, the figures can be updated in place.
    private var shownStructure: [String] = []

    private func currentStructure() -> [String] {
        var structure: [String] = []
        structure.reserveCapacity(visible.count)
        for node in visible {
            structure.append("\(node.app.id)#\(node.children.count)")
            if outlineView.isItemExpanded(node) {
                structure.append(contentsOf: node.children.map { String($0.process.pid) })
            }
        }
        return structure
    }

    /// Two significant digits, roughly what the cells show. Sorting on raw values would reshuffle
    /// rows on every sample over differences nobody can see.
    private static func displayed(_ value: Double) -> Double {
        guard value != 0, value.isFinite else { return 0 }
        let scale = pow(10, floor(log10(abs(value))) - 1)
        return (value / scale).rounded() * scale
    }

    private func sort(_ apps: [AppNode]) -> [AppNode] {
        let column = columns.first { $0.id == sortKey }
        let sortedApps: [AppNode]
        if let column {
            sortedApps = apps.sorted {
                let a = Self.displayed(column.app($0.app)), b = Self.displayed(column.app($1.app))
                if a == b { return $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
                return ascending ? a < b : a > b
            }
            for node in sortedApps {
                node.children.sort {
                    let a = Self.displayed(column.process($0.process)), b = Self.displayed(column.process($1.process))
                    if a == b { return $0.process.pid < $1.process.pid }
                    return ascending ? a < b : a > b
                }
            }
        } else {
            sortedApps = apps.sorted {
                let order = $0.app.name.localizedCaseInsensitiveCompare($1.app.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            for node in sortedApps {
                node.children.sort { $0.process.name.localizedCaseInsensitiveCompare($1.process.name) == .orderedAscending }
            }
        }
        return sortedApps
    }

    // MARK: - Outline data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return visible.count }
        return (item as? AppNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return visible[index] }
        return (item as! AppNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? AppNode else { return false }
        return node.children.count > 1 || (node.children.count == 1 && node.children[0].process.name != node.app.name)
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key
        ascending = descriptor.ascending
        visible = sort(visible)
        shownStructure = currentStructure()
        reloadKeepingSelection()
    }

    // MARK: - Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn else { return nil }
        let id = tableColumn.identifier.rawValue
        let cell: NSView
        switch id {
        case "name": cell = outlineView.makeView(withIdentifier: NameCell.identifier, owner: nil) ?? NameCell()
        case "share": cell = outlineView.makeView(withIdentifier: ShareCell.identifier, owner: nil) ?? ShareCell()
        default:
            guard columns.contains(where: { $0.id == id }) else { return nil }
            cell = outlineView.makeView(withIdentifier: NumberCell.identifier, owner: nil) ?? NumberCell()
        }
        configure(cell, columnID: id, item: item)
        return cell
    }

    private func configure(_ view: NSView, columnID id: String, item: Any) {
        if let cell = view as? NameCell {
            if let node = item as? AppNode {
                cell.configure(icon: AppIcons.icon(for: node.app), name: node.app.name, detail: nil, dimmed: false)
            } else if let node = item as? ProcessNode {
                let process = node.process
                cell.configure(icon: nil, name: process.name, detail: "\(process.pid)", dimmed: !process.isAccessible)
            }
        } else if let cell = view as? ShareCell {
            let bytes: Double
            if let node = item as? AppNode { bytes = Double(node.app.memory) } else { bytes = Double((item as? ProcessNode)?.process.memory ?? 0) }
            cell.meter.value = bytes / memoryTotal
            cell.meter.color = Theme.color(for: .memory)
            cell.label.set(Format.percent(bytes / memoryTotal))
        } else if let cell = view as? NumberCell, let column = columns.first(where: { $0.id == id }) {
            if let node = item as? AppNode {
                cell.label.set(column.text(column.app(node.app)))
                cell.label.textColor = .labelColor
            } else if let node = item as? ProcessNode {
                let process = node.process
                let unavailable = !process.isAccessible && id != "processes"
                cell.label.set(unavailable ? "–" : column.text(column.process(process)))
                cell.label.textColor = .secondaryLabelColor
            }
        }
    }

    /// Updates the figures of every row view the table holds (on screen and the few it keeps ready
    /// just outside), without rebuilding any views.
    private func refreshVisibleCells() {
        let columns = outlineView.tableColumns
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let item = self.outlineView.item(atRow: row) else { return }
            for (index, column) in columns.enumerated() {
                guard let cell = rowView.view(atColumn: index) as? NSView else { continue }
                self.configure(cell, columnID: column.identifier.rawValue, item: item)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is AppNode ? 30 : 24
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let item = outlineView.item(atRow: outlineView.clickedRow)
        guard let node = item as? AppNode else { return }
        if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { outlineView.expandItem(node) }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let item = outlineView.item(atRow: outlineView.clickedRow)
        if let node = item as? AppNode {
            let app = node.app
            let isMacOS = app.id == AppGrouper.systemGroupID
            menu.addItem(action("Quit \(app.name)…", #selector(quitApp(_:)), node, enabled: !isMacOS))
            menu.addItem(action("Force Quit \(app.name)…", #selector(forceQuitApp(_:)), node, enabled: !isMacOS))
            menu.addItem(.separator())
            if app.bundlePath != nil {
                menu.addItem(action("Show in Finder", #selector(showInFinder(_:)), app.bundlePath as Any))
            }
            menu.addItem(action("Copy Name", #selector(copyText(_:)), app.name))
        } else if let node = item as? ProcessNode {
            let process = node.process
            let quittable = process.pid > 0 && process.pid != getpid()
            menu.addItem(action("Quit Process…", #selector(quitProcess(_:)), node, enabled: quittable))
            menu.addItem(action("Force Quit Process…", #selector(forceQuitProcess(_:)), node, enabled: quittable))
            menu.addItem(.separator())
            if let path = process.path {
                menu.addItem(action("Show in Finder", #selector(showInFinder(_:)), path))
            }
            menu.addItem(action("Copy PID", #selector(copyText(_:)), String(process.pid)))
            if let path = process.path { menu.addItem(action("Copy Path", #selector(copyText(_:)), path)) }
        }
    }

    private func action(_ title: String, _ selector: Selector, _ object: Any, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? selector : nil, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.isEnabled = enabled
        return item
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? AppNode else { return }
        ProcessControl.quit(node.app, force: false, window: outlineView.window)
    }

    @objc private func forceQuitApp(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? AppNode else { return }
        ProcessControl.quit(node.app, force: true, window: outlineView.window)
    }

    @objc private func quitProcess(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ProcessNode else { return }
        ProcessControl.quit(node.process, force: false, window: outlineView.window)
    }

    @objc private func forceQuitProcess(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ProcessNode else { return }
        ProcessControl.quit(node.process, force: true, window: outlineView.window)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Cell views

private final class NameCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NameCell")
    private let icon = NSImageView()
    private let name = NSTextField.label("", size: 13)
    private let detail = NSTextField.number("", size: 11, color: .tertiaryLabelColor)
    private var iconWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView.horizontal([icon, name, detail], spacing: 7)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(icon image: NSImage?, name text: String, detail detailText: String?, dimmed: Bool) {
        icon.image = image
        icon.isHidden = image == nil
        iconWidth.constant = image == nil ? 0 : 20
        name.set(text)
        name.font = .systemFont(ofSize: image == nil ? 12 : 13, weight: image == nil ? .regular : .medium)
        name.textColor = dimmed ? .secondaryLabelColor : .labelColor
        detail.set(detailText ?? "")
        detail.isHidden = detailText == nil
    }
}

private final class NumberCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NumberCell")
    let label = NSTextField.number("", size: 12)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.alignment = .right
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class ShareCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ShareCell")
    let meter = MeterView(height: 5)
    let label = NSTextField.number("", size: 11, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.alignment = .right
        let stack = NSStackView.horizontal([meter, label], spacing: 6)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
