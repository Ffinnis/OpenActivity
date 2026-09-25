//
//  MainWindowController.swift
//  OpenActivity
//
//  The main window: a sidebar of pages with live figures, and the selected page beside it.
//

import AppKit

/// Pages implement this to receive snapshots while they are on screen.
protocol LivePage: AnyObject {
    func update(with snapshot: SystemSnapshot)
    /// Filters app lists by name. Pages without lists ignore it.
    func applySearch(_ text: String)
}

extension LivePage {
    func applySearch(_ text: String) {}
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    private let splitViewController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let container = NSViewController()
    private var pages: [Metric: NSViewController] = [:]
    private(set) var currentPage: Metric = .overview
    private var token: Monitor.Token?
    private var searchField: NSSearchField?
    private var searchText = ""

    private static let searchItem = NSToolbarItem.Identifier("search")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenActivity"
        window.minSize = NSSize(width: 860, height: 560)
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        container.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 620
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.autosaveName = "MainSplit"
        window.contentViewController = splitViewController
        if !window.setFrameUsingName("MainWindow") {
            window.setContentSize(NSSize(width: 1120, height: 760))
            window.center()
        }

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        sidebar.onSelect = { [weak self] page in self?.show(page) }
        show(Preferences.shared.lastPage)

        token = Monitor.shared.observe { [weak self] snapshot in self?.update(snapshot) }
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, Monitor.shared.hasSample else { return }
            self.update(Monitor.shared.snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ page: Metric) {
        currentPage = page
        Preferences.shared.lastPage = page
        sidebar.select(page)

        let controller = pages[page] ?? makePage(page)
        pages[page] = controller
        for child in container.children where child !== controller {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        if controller.parent == nil {
            container.addChild(controller)
            container.view.addSubview(controller.view)
            controller.view.pinEdges(to: container.view)
        }
        window?.subtitle = page == .overview ? "" : page.title
        searchField?.isEnabled = Metric.appMetrics.contains(page) || page == .projects
        if let live = controller as? LivePage {
            live.applySearch(searchText)
            if Monitor.shared.hasSample { live.update(with: Monitor.shared.snapshot) }
        }
    }

    private func makePage(_ page: Metric) -> NSViewController {
        switch page {
        case .overview:
            let overview = OverviewViewController()
            overview.onOpen = { [weak self] page in self?.show(page) }
            return overview
        case .cpu, .memory, .disk, .network, .gpu, .battery:
            return MetricPageViewController(metric: page)
        case .sensors:
            return SensorsViewController()
        case .sound:
            return SoundViewController()
        case .projects:
            return ProjectsViewController()
        }
    }

    private func update(_ snapshot: SystemSnapshot) {
        sidebar.update(with: snapshot)
        guard window?.isVisible == true, window?.occlusionState.contains(.visible) == true else { return }
        (pages[currentPage] as? LivePage)?.update(with: snapshot)
    }

    // MARK: - Window

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window?.occlusionState.contains(.visible) == true && window?.isVisible == true
        Monitor.shared.setInteractive(visible, reason: "main-window")
        if visible, Monitor.shared.hasSample { update(Monitor.shared.snapshot) }
    }

    func windowWillClose(_ notification: Notification) {
        Monitor.shared.setInteractive(false, reason: "main-window")
    }

    @objc func focusSearch(_ sender: Any?) {
        guard let searchField, searchField.isEnabled else { return }
        window?.makeFirstResponder(searchField)
    }

    /// Copies the overview as an image, the way it looks right now.
    func copyDashboardImage() {
        show(.overview)
        guard let view = pages[.overview]?.view else { return }
        view.layoutSubtreeIfNeeded()
        let target = (view as? NSScrollView)?.documentView ?? view
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        let image = NSImage(size: target.bounds.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.searchItem else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
        item.searchField.placeholderString = "Search apps and processes"
        item.searchField.delegate = self
        item.preferredWidthForSearchField = 240
        searchField = item.searchField
        searchField?.isEnabled = Metric.appMetrics.contains(currentPage) || currentPage == .projects
        return item
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        searchText = field.stringValue
        (pages[currentPage] as? LivePage)?.applySearch(searchText)
    }
}

// MARK: - Sidebar

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String)
        case page(Metric)
    }

    var onSelect: ((Metric) -> Void)?

    private let rows: [Row] = [
        .header("Monitor"),
        .page(.overview), .page(.cpu), .page(.memory), .page(.disk), .page(.network), .page(.gpu), .page(.battery),
        .header("Mac"),
        .page(.sensors), .page(.sound), .page(.projects),
    ]
    private let tableView = NSTableView()
    private var figures: [Metric: String] = [:]
    private var isSelecting = false

    override func loadView() {
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.rowSizeStyle = .default
        tableView.floatsGroupRows = false
        tableView.focusRingType = .none
        let column = NSTableColumn(identifier: .init("page"))
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    func select(_ page: Metric) {
        guard let index = rows.firstIndex(where: { if case .page(let p) = $0 { return p == page } else { return false } }) else { return }
        isSelecting = true
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        isSelecting = false
    }

    func update(with snapshot: SystemSnapshot) {
        var next: [Metric: String] = [
            .cpu: Format.percent(snapshot.cpu.total),
            .memory: Format.memory(snapshot.memory.used),
            .disk: snapshot.disk.rootVolume.map { Format.bytes($0.free) } ?? "",
            .network: "↓ " + Format.rate(snapshot.network.inRate),
            .gpu: Format.percent(snapshot.gpu.utilization),
            .battery: snapshot.battery.isPresent ? Format.percent(snapshot.battery.charge) : Format.watts(snapshot.battery.systemPower),
            .sensors: Format.temperature(snapshot.sensors.cpuTemperature),
        ]
        if !snapshot.projects.isEmpty { next[.projects] = "\(snapshot.projects.count)" }
        if next[.sensors] == "–" { next[.sensors] = nil }
        guard next != figures else { return }
        figures = next
        for (index, row) in rows.enumerated() {
            guard case .page(let page) = row,
                  let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarCell else { continue }
            cell.figure.set(figures[page] ?? "")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .page = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 }
        return 30
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField.label(title, size: 11, weight: .semibold, color: .tertiaryLabelColor)
            let cell = NSTableCellView()
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        case .page(let page):
            let cell = tableView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
            cell.configure(page)
            cell.figure.set(figures[page] ?? "")
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelecting, tableView.selectedRow >= 0, case .page(let page) = rows[tableView.selectedRow] else { return }
        onSelect?(page)
    }
}

private final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
    let icon = NSImageView()
    let title = NSTextField.label("", size: 13)
    let figure = NSTextField.number("", size: 11, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        figure.alignment = .right
        figure.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView.horizontal([icon, title, NSView.spacer(), figure], spacing: 8)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
        imageView = icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var page: Metric?

    func configure(_ page: Metric) {
        self.page = page
        title.stringValue = page.title
        updateIcon()
    }

    /// Colored icons disappear on the blue selection highlight, so the selected row's icon turns white.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateIcon() }
    }

    private func updateIcon() {
        guard let page else { return }
        let color = backgroundStyle == .emphasized ? NSColor.white : Theme.color(for: page)
        icon.image = NSImage.symbol(page.symbolName, size: 13, weight: .medium, color: color)
    }
}
