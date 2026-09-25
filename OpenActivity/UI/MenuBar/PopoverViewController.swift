//
//  PopoverViewController.swift
//  OpenActivity
//
//  The compact dashboard shown from the menu bar: an overview, one tab per metric and running
//  dev projects. Every view is built once; snapshots only update text, charts and row contents,
//  and every page has a fixed height so the popover never changes size while it is open.
//

import AppKit

final class PopoverViewController: NSViewController {
    /// Closes the popover. Set by the status item.
    var dismiss: (() -> Void)?

    static let width: CGFloat = 360
    private static let tabs: [Metric] = [.overview, .cpu, .memory, .disk, .network, .gpu, .battery, .projects]
    private static let tabKey = "popover.tab"

    private var selected: Metric
    private var tabButtons: [Metric: TabButton] = [:]
    private var pages: [Metric: NSView] = [:]
    private var overviewPage: OverviewPage!
    private var metricPages: [Metric: MetricPage] = [:]
    private var projectsPage: ProjectsPage!
    private var token: Monitor.Token?
    private var isOnScreen = false

    // Traffic since launch, integrated from the sampled rates.
    private var sessionReceived: Double = 0
    private var sessionSent: Double = 0
    private var lastSampleDate: Date?

    private var cpuDayAverage: Double?
    private var cpuAverageFetched: Date?

    init() {
        let stored = Metric(rawValue: UserDefaults.standard.string(forKey: Self.tabKey) ?? "")
        selected = stored.flatMap { Self.tabs.contains($0) ? $0 : nil } ?? .overview
        super.init(nibName: nil, bundle: nil)
        // Observed from launch so the session totals are complete; the UI only updates while shown.
        token = Monitor.shared.observe { [weak self] snapshot in self?.receive(snapshot) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let token { Monitor.shared.removeObserver(token) }
    }

    // MARK: - Building

    override func loadView() {
        let root = NSView()
        let stack = NSStackView.vertical(spacing: 0, alignment: .centerX)
        root.addSubview(stack)
        stack.pinEdges(to: root)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        let tabBar = makeTabBar()
        stack.addArrangedSubview(tabBar)
        tabBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        stack.setCustomSpacing(8, after: tabBar)

        let topSeparator = Self.separator()
        stack.addArrangedSubview(topSeparator)
        topSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let pageContainer = makePages()
        stack.addArrangedSubview(pageContainer)
        pageContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let bottomSeparator = Self.separator()
        stack.addArrangedSubview(bottomSeparator)
        bottomSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let footer = makeFooter()
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)

        view = root
        showSelectedPage()

        // Every page reserves its full height, so the size measured once holds for good.
        let size = root.fittingSize
        root.frame = NSRect(origin: .zero, size: size)
        preferredContentSize = size
    }

    private func makeTabBar() -> NSView {
        let bar = NSStackView.horizontal(spacing: 2)
        bar.distribution = .fillEqually
        for metric in Self.tabs {
            let button = TabButton(metric: metric)
            button.onClick = { [weak self] in self?.select(metric) }
            tabButtons[metric] = button
            bar.addArrangedSubview(button)
        }
        return bar
    }

    private func makePages() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let open: (Metric) -> Void = { [weak self] metric in self?.select(metric) }
        let openMain: (Metric) -> Void = { [weak self] metric in self?.openMainWindow(metric) }
        let beforeModal: () -> Void = { [weak self] in self?.dismiss?() }

        overviewPage = OverviewPage(onSelect: open, onOpenApp: openMain, beforeModal: beforeModal)
        pages[.overview] = overviewPage
        for metric in Metric.appMetrics {
            let page = MetricPage(metric: metric, stats: Self.statTitles(for: metric), onOpenApp: openMain, beforeModal: beforeModal)
            metricPages[metric] = page
            pages[metric] = page
        }
        projectsPage = ProjectsPage(onOpenProjects: { openMain(.projects) }, beforeModal: beforeModal)
        pages[.projects] = projectsPage

        for page in pages.values {
            page.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(page)
            // Hidden pages keep their constraints, so the container is as tall as the tallest page.
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                page.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                page.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                page.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
            ])
        }
        return container
    }

    private func makeFooter() -> NSView {
        let openButton = NSButton(title: "Open OpenActivity", target: self, action: #selector(openMainWindowFromFooter))
        openButton.bezelStyle = .push
        openButton.controlSize = .regular

        let settingsButton = NSButton(image: NSImage.symbol("gearshape", size: 14) ?? NSImage(), target: self, action: #selector(openSettings))
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.toolTip = "Settings"
        settingsButton.setAccessibilityLabel("Settings")

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .push
        quitButton.toolTip = "Quit OpenActivity"

        let footer = NSStackView.horizontal([openButton, NSView.spacer(), settingsButton, quitButton], spacing: 10)
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        return footer
    }

    private static func statTitles(for metric: Metric) -> [(String, NSColor?)] {
        switch metric {
        case .cpu: return [("User", Theme.color(for: .cpu)), ("System", Theme.secondaryColor(for: .cpu)), ("Load", nil), ("24 h avg", nil)]
        case .memory: return [("App", Theme.MemoryPart.app), ("Wired", Theme.MemoryPart.wired), ("Compressed", Theme.MemoryPart.compressed), ("Swap", nil)]
        case .disk: return [("Read", Theme.color(for: .disk)), ("Write", Theme.secondaryColor(for: .disk)), ("Used", nil), ("Free", nil)]
        case .network: return [("Downloaded", Theme.color(for: .network)), ("Uploaded", Theme.secondaryColor(for: .network)), ("Interface", nil)]
        case .gpu: return [("Memory", nil), ("Cores", nil), ("Temperature", nil)]
        case .battery: return [("Power", nil), ("Health", nil), ("Cycles", nil)]
        default: return []
        }
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    // MARK: - Appearing

    override func viewWillAppear() {
        super.viewWillAppear()
        isOnScreen = true
        if Monitor.shared.hasSample { update(Monitor.shared.snapshot) }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isOnScreen = false
        // The pointer may have left while the popover was closing.
        for page in pages.values { HoverRow.resetHover(in: page) }
        tabButtons.values.forEach { $0.resetHover() }
    }

    // MARK: - Tabs

    private func select(_ metric: Metric) {
        guard metric != selected else { return }
        selected = metric
        UserDefaults.standard.set(metric.rawValue, forKey: Self.tabKey)
        showSelectedPage()
        if Monitor.shared.hasSample { update(Monitor.shared.snapshot) }
    }

    private func showSelectedPage() {
        for (metric, button) in tabButtons { button.isSelected = metric == selected }
        for (metric, page) in pages { page.isHidden = metric != selected }
    }

    // MARK: - Actions

    private func openMainWindow(_ page: Metric) {
        dismiss?()
        AppDelegate.shared.showMainWindow(page: page)
    }

    @objc private func openMainWindowFromFooter() {
        openMainWindow(selected)
    }

    @objc private func openSettings() {
        dismiss?()
        AppDelegate.shared.showSettings(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Updating

    private func receive(_ snapshot: SystemSnapshot) {
        if let lastSampleDate {
            // Capped so a long sleep can't turn one rate into a huge total.
            let elapsed = min(max(0, snapshot.date.timeIntervalSince(lastSampleDate)), 60)
            sessionReceived += snapshot.network.inRate * elapsed
            sessionSent += snapshot.network.outRate * elapsed
        }
        lastSampleDate = snapshot.date
        if isOnScreen { update(snapshot) }
    }

    private func update(_ snapshot: SystemSnapshot) {
        guard isViewLoaded else { return }
        let recent = Monitor.shared.recent
        switch selected {
        case .overview:
            overviewPage.update(snapshot, recent: recent, apps: visibleApps(snapshot, by: .cpu, limit: 3))
        case .projects:
            projectsPage.update(snapshot.projects)
        default:
            guard let page = metricPages[selected] else { return }
            if selected == .cpu { refreshCPUAverageIfNeeded() }
            update(page, snapshot: snapshot, recent: recent)
        }
    }

    private func visibleApps(_ snapshot: SystemSnapshot, by metric: Metric, limit: Int) -> [AppGroup] {
        let showSystem = Preferences.shared.showSystemProcesses
        return Array(snapshot.topApps(by: metric).lazy.filter { showSystem || !$0.isSystem }.prefix(limit))
    }

    private func refreshCPUAverageIfNeeded() {
        if let cpuAverageFetched, Date().timeIntervalSince(cpuAverageFetched) < 60 { return }
        cpuAverageFetched = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let average = HistoryStore.shared.average(.cpu, since: Date().addingTimeInterval(-86_400))
            DispatchQueue.main.async { self?.cpuDayAverage = average }
        }
    }

    private func update(_ page: MetricPage, snapshot: SystemSnapshot, recent: RecentHistory) {
        let metric = page.metric
        let color = Theme.color(for: metric)
        let secondary = Theme.secondaryColor(for: metric)
        let apps = visibleApps(snapshot, by: metric, limit: MetricPage.appRowCount)
        let appValue: (AppGroup) -> String

        switch metric {
        case .cpu:
            let cpu = snapshot.cpu
            page.figure.update(splitting: Format.percent(cpu.total))
            var caption = cpu.modelName
            if cpu.logicalCores > 0 { caption += " · \(cpu.logicalCores) cores" }
            page.caption.set(caption)
            page.setChart([ChartView.Series(values: recent.cpu.values, color: color)], maxValue: 1)
            page.setStats([
                Format.percent(cpu.user),
                Format.percent(cpu.system),
                String(format: "%.2f", cpu.loadAverage.first ?? 0),
                cpuDayAverage.map(Format.percent) ?? "–",
            ])
            appValue = { Format.cpu($0.cpuPercent) }

        case .memory:
            let memory = snapshot.memory
            page.figure.update(splitting: Format.memory(memory.used))
            page.caption.set("of \(Format.memory(memory.total)) · \(memory.pressure.title) pressure")
            page.setChart([ChartView.Series(values: recent.memory.values, color: color)], maxValue: 1)
            page.setStats([Format.memory(memory.app), Format.memory(memory.wired), Format.memory(memory.compressed), Format.memory(memory.swapUsed)])
            appValue = { Format.memory($0.memory) }

        case .disk:
            let disk = snapshot.disk
            if let root = disk.rootVolume {
                page.figure.update(splitting: Format.percent(root.total == 0 ? 0 : Double(root.used) / Double(root.total)))
                page.caption.set("used of \(Format.bytes(root.total)) on \(root.name)")
                page.setStats([Format.rate(disk.readRate), Format.rate(disk.writeRate), Format.bytes(root.used), Format.bytes(root.free)])
            } else {
                page.figure.update("–")
                page.caption.set("No startup volume found")
                page.setStats([Format.rate(disk.readRate), Format.rate(disk.writeRate), "–", "–"])
            }
            page.setChart([
                ChartView.Series(values: recent.diskRead.values, color: color, name: "Read"),
                ChartView.Series(values: recent.diskWrite.values, color: secondary, name: "Write", mirrored: true),
            ], maxValue: nil)
            appValue = { Format.rate($0.diskReadRate + $0.diskWriteRate) }

        case .network:
            let network = snapshot.network
            page.figure.update(splitting: Format.rate(network.inRate))
            page.caption.set("down · ↑ \(Format.rate(network.outRate)) up")
            page.setChart([
                ChartView.Series(values: recent.netIn.values, color: color, name: "Down"),
                ChartView.Series(values: recent.netOut.values, color: secondary, name: "Up", mirrored: true),
            ], maxValue: nil)
            let interface = [network.interfaceKind, network.interfaceName].filter { !$0.isEmpty }.joined(separator: " · ")
            page.setStats([Format.bytes(sessionReceived), Format.bytes(sessionSent), interface.isEmpty ? "–" : interface])
            appValue = { Format.rate($0.netInRate + $0.netOutRate) }

        case .gpu:
            let gpu = snapshot.gpu
            page.figure.update(splitting: Format.percent(gpu.utilization))
            page.caption.set(gpu.name.isEmpty ? "Graphics" : gpu.name)
            page.setChart([ChartView.Series(values: recent.gpu.values, color: color)], maxValue: 1)
            page.setStats([
                Format.memory(gpu.memoryInUse),
                gpu.coreCount.map { Format.number($0) } ?? "–",
                Format.temperature(snapshot.sensors.gpuTemperature),
            ])
            appValue = { Format.cpu($0.gpuPercent) }

        case .battery:
            let battery = snapshot.battery
            if battery.isPresent {
                page.figure.update(splitting: Format.percent(battery.charge))
                var caption = Self.batteryStatus(battery)
                if let adapter = battery.adapterWatts, battery.isPluggedIn, adapter > 0 {
                    caption += " · \(Int(adapter.rounded())) W adapter"
                }
                page.caption.set(caption)
                page.setStats([Format.watts(battery.systemPower), Format.percent(battery.health), Format.number(battery.cycleCount)])
            } else {
                page.figure.update(splitting: Format.watts(battery.systemPower))
                page.caption.set("drawn by this Mac right now")
                page.setStats([Format.watts(battery.systemPower), "–", "–"])
            }
            page.setChart([ChartView.Series(values: recent.power.values, color: color)], maxValue: nil)
            appValue = { Format.watts($0.power) }

        default:
            return
        }
        page.setApps(apps.map { ($0, appValue($0)) })
    }

    static func batteryStatus(_ battery: BatteryStats) -> String {
        if battery.isFullyCharged { return "Fully charged" }
        if battery.isCharging {
            return battery.timeRemaining.map { "Charging · \(Format.duration($0)) to full" } ?? "Charging"
        }
        if battery.isPluggedIn { return "Plugged in, not charging" }
        return battery.timeRemaining.map { "\(Format.duration($0)) left" } ?? "On battery"
    }
}

// MARK: - Overview

private final class OverviewPage: NSStackView {
    private let uptimeLabel = NSTextField.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let alertLabel = NSTextField.label("", size: 11, weight: .medium, color: .systemOrange)
    private var rows: [Metric: MetricRow] = [:]
    private var appRows: [AppRow] = []
    private static let rowMetrics: [Metric] = [.cpu, .memory, .network, .disk, .gpu, .battery]

    init(onSelect: @escaping (Metric) -> Void, onOpenApp: @escaping (Metric) -> Void, beforeModal: @escaping () -> Void) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 8

        uptimeLabel.font = Theme.numberFont(12, weight: .medium)
        alertLabel.alignment = .right
        alertLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let header = NSStackView.horizontal([uptimeLabel, NSView.spacer(minWidth: 8), alertLabel], spacing: 4)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addFullWidth(header)

        let card = CardView([], spacing: 0)
        card.contentInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        for (index, metric) in Self.rowMetrics.enumerated() {
            if index > 0 {
                let separator = PopoverViewController.separator()
                card.content.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: card.content.widthAnchor, constant: -16).isActive = true
            }
            let row = MetricRow(metric: metric)
            row.onClick = { onSelect(metric) }
            row.toolTip = "Show \(metric.title)"
            rows[metric] = row
            card.content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
        }
        card.content.alignment = .centerX
        addFullWidth(card)
        setCustomSpacing(14, after: card)

        addFullWidth(SectionHeader("Busiest right now"))
        for _ in 0..<3 {
            let row = AppRow(metric: .cpu, onOpen: onOpenApp, beforeModal: beforeModal)
            appRows.append(row)
            addFullWidth(row)
        }
        if let first = appRows.first { setCustomSpacing(2, after: arrangedSubviews[arrangedSubviews.firstIndex(of: first)! - 1]) }
        appRows.dropLast().forEach { setCustomSpacing(0, after: $0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ snapshot: SystemSnapshot, recent: RecentHistory, apps: [AppGroup]) {
        uptimeLabel.set("Up \(Format.duration(snapshot.uptime)) · \(Format.processes(snapshot.processCount))")

        let dayAgo = Date().addingTimeInterval(-86_400)
        let alerts = AlertEngine.shared.recentAlerts.filter { $0.date > dayAgo }
        if let latest = alerts.first {
            alertLabel.set(alerts.count == 1 ? "1 alert today" : "\(alerts.count) alerts today")
            alertLabel.toolTip = "\(latest.title)\n\(latest.body)"
        } else {
            alertLabel.set("")
            alertLabel.toolTip = nil
        }

        let cpu = snapshot.cpu
        rows[.cpu]?.update(value: Format.percent(cpu.total), detail: "load " + String(format: "%.2f", cpu.loadAverage.first ?? 0),
                           series: [.init(values: recent.cpu.values, color: Theme.color(for: .cpu))], maxValue: 1)

        let memory = snapshot.memory
        rows[.memory]?.update(value: Format.memory(memory.used), detail: "of \(Format.memory(memory.total))",
                              series: [.init(values: recent.memory.values, color: Theme.color(for: .memory))], maxValue: 1)

        let network = snapshot.network
        rows[.network]?.update(value: "↓ \(Format.rate(network.inRate))", detail: "↑ \(Format.rate(network.outRate))",
                               series: [.init(values: recent.netIn.values, color: Theme.color(for: .network)),
                                        .init(values: recent.netOut.values, color: Theme.secondaryColor(for: .network), mirrored: true)],
                               maxValue: nil)

        let root = snapshot.disk.rootVolume
        rows[.disk]?.update(value: root.map { Format.bytes($0.free) } ?? "–", detail: root == nil ? "" : "free",
                            series: [.init(values: recent.diskRead.values, color: Theme.color(for: .disk)),
                                     .init(values: recent.diskWrite.values, color: Theme.secondaryColor(for: .disk), mirrored: true)],
                            maxValue: nil)

        rows[.gpu]?.update(value: Format.percent(snapshot.gpu.utilization), detail: "",
                           series: [.init(values: recent.gpu.values, color: Theme.color(for: .gpu))], maxValue: 1)

        let battery = snapshot.battery
        let energy = rows[.battery]
        if battery.isPresent {
            energy?.titleLabel.set("Battery")
            energy?.update(value: Format.percent(battery.charge), detail: PopoverViewController.batteryStatus(battery),
                           series: [.init(values: recent.battery.values, color: Theme.color(for: .battery))], maxValue: 1)
        } else {
            energy?.titleLabel.set("Power")
            energy?.update(value: Format.watts(battery.systemPower), detail: "in use",
                           series: [.init(values: recent.power.values, color: Theme.color(for: .battery))], maxValue: nil)
        }

        for (index, row) in appRows.enumerated() {
            let app = index < apps.count ? apps[index] : nil
            row.update(app, value: app.map { Format.cpu($0.cpuPercent) } ?? "")
        }
    }
}

// MARK: - Metric tab

private final class MetricPage: NSStackView {
    static let appRowCount = 5

    let metric: Metric
    let figure = BigFigureView(size: 28)
    let caption = NSTextField.label("", size: 11, color: .secondaryLabelColor)
    private let chart = ChartView(style: .sparkline, height: 44)
    private var stats: [StatView] = []
    private var appRows: [AppRow] = []

    init(metric: Metric, stats titles: [(String, NSColor?)], onOpenApp: @escaping (Metric) -> Void, beforeModal: @escaping () -> Void) {
        self.metric = metric
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 8

        figure.valueLabel.textColor = .labelColor
        let heading = NSStackView.vertical([figure, caption], spacing: 1)

        stats = titles.map { StatView(title: $0.0, size: 13, dot: $0.1) }
        if metric == .network {
            stats.prefix(2).forEach { $0.toolTip = "Since OpenActivity started" }
        }
        let statRow = NSStackView.horizontal(stats, spacing: 8, alignment: .top)
        statRow.distribution = .fillEqually

        let card = CardView([heading, chart, statRow], spacing: 10)
        card.contentInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        heading.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
        chart.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
        statRow.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
        addFullWidth(card)
        setCustomSpacing(14, after: card)

        let header = SectionHeader("Top apps")
        addFullWidth(header)
        setCustomSpacing(2, after: header)
        for _ in 0..<Self.appRowCount {
            let row = AppRow(metric: metric, onOpen: onOpenApp, beforeModal: beforeModal)
            appRows.append(row)
            addFullWidth(row)
            setCustomSpacing(0, after: row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setChart(_ series: [ChartView.Series], maxValue: Double?) {
        chart.maxValue = maxValue
        chart.series = series
    }

    func setStats(_ values: [String]) {
        for (stat, value) in zip(stats, values) { stat.valueLabel.set(value) }
    }

    func setApps(_ apps: [(AppGroup, String)]) {
        for (index, row) in appRows.enumerated() {
            if index < apps.count {
                row.update(apps[index].0, value: apps[index].1)
            } else {
                row.update(nil, value: "")
            }
        }
    }
}

// MARK: - Projects tab

private final class ProjectsPage: NSStackView {
    static let rowCount = 6

    private let summaryLabel = NSTextField.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let emptyLabel = NSTextField.label("No dev servers are running", size: 12, color: .tertiaryLabelColor)
    private let moreButton: NSButton
    private var rows: [ProjectRow] = []
    private let onOpenProjects: () -> Void

    init(onOpenProjects: @escaping () -> Void, beforeModal: @escaping () -> Void) {
        self.onOpenProjects = onOpenProjects
        moreButton = NSButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 0

        summaryLabel.font = Theme.numberFont(12, weight: .medium)
        let header = NSStackView.horizontal([summaryLabel, NSView.spacer()], spacing: 4)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addFullWidth(header)
        setCustomSpacing(8, after: header)

        for _ in 0..<Self.rowCount {
            let row = ProjectRow(onOpen: onOpenProjects, beforeModal: beforeModal)
            rows.append(row)
            addFullWidth(row)
        }

        moreButton.target = self
        moreButton.action = #selector(openProjects)
        moreButton.isBordered = false
        moreButton.contentTintColor = .linkColor
        moreButton.font = .systemFont(ofSize: 12, weight: .medium)
        let footer = NSStackView.horizontal([moreButton, NSView.spacer()], spacing: 4)
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        if let last = rows.last { setCustomSpacing(6, after: last) }
        addFullWidth(footer)

        // Centered over the row area without taking part in the layout.
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        if let first = rows.first, let last = rows.last {
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: first.topAnchor, constant: (last.frame.maxY - first.frame.minY) / 2),
            ])
            emptyLabel.centerYAnchor.constraint(equalTo: first.bottomAnchor, constant: 24).isActive = false
        }
        emptyLabel.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ projects: [DevProject]) {
        let sorted = projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let memory = sorted.reduce(UInt64(0)) { $0 + $1.memory }
        let ports = Set(sorted.flatMap(\.ports)).count
        if sorted.isEmpty {
            summaryLabel.set("Nothing running")
        } else {
            let projectText = sorted.count == 1 ? "1 project" : "\(sorted.count) projects"
            let portText = ports == 1 ? "1 port open" : "\(ports) ports open"
            summaryLabel.set("\(projectText) · \(Format.memory(memory)) · \(portText)")
        }
        emptyLabel.isHidden = !sorted.isEmpty

        for (index, row) in rows.enumerated() {
            row.update(index < sorted.count ? sorted[index] : nil)
        }

        let hidden = sorted.count - Self.rowCount
        if hidden > 0 {
            moreButton.title = "and \(hidden) more…"
        } else {
            moreButton.title = sorted.isEmpty ? "Open Projects…" : "Show all in OpenActivity…"
        }
    }

    @objc private func openProjects() {
        onOpenProjects()
    }

    override func layout() {
        super.layout()
        // Keep the empty-state label centered in the space the rows reserve.
        if let first = rows.first, let last = rows.last {
            let area = first.frame.union(last.frame)
            emptyLabel.constraints.forEach { _ in }
            if let centerY = constraints.first(where: { $0.firstItem === emptyLabel && $0.firstAttribute == .centerY }) {
                let offset = area.height / 2
                if centerY.constant != offset { centerY.constant = offset }
            }
        }
    }
}

private final class ProjectRow: HoverRow {
    private let dot = DotView(color: .systemGreen, diameter: 7)
    private let nameLabel = NSTextField.label("", size: 12.5, weight: .semibold)
    private let memoryLabel = NSTextField.number("", size: 12, color: .secondaryLabelColor)
    private let portStack = NSStackView.horizontal(spacing: 4)
    private let pathLabel = NSTextField.label("", size: 11, color: .tertiaryLabelColor)
    private var shownPorts: [UInt16]?
    private var project: DevProject?
    private let beforeModal: () -> Void

    init(onOpen: @escaping () -> Void, beforeModal: @escaping () -> Void) {
        self.beforeModal = beforeModal
        memoryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        memoryLabel.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView.horizontal([dot, nameLabel, NSView.spacer(minWidth: 6), memoryLabel], spacing: 6)
        portStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bottom = NSStackView.horizontal([portStack, pathLabel, NSView.spacer()], spacing: 6)
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 13, bottom: 0, right: 0)
        let content = NSStackView.vertical([top, bottom], spacing: 3)
        super.init(content: content, height: 42)
        top.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        // Fixed height for the second line whether it shows pills or only a path.
        bottom.heightAnchor.constraint(equalToConstant: 16).isActive = true
        onClick = { onOpen() }
        menuProvider = { [weak self] in self?.makeMenu() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ project: DevProject?) {
        self.project = project
        isActive = project != nil
        alphaValue = project == nil ? 0 : 1
        guard let project else { return }
        nameLabel.set(project.name)
        memoryLabel.set(Format.memory(project.memory))
        dot.color = project.isIdle ? .tertiaryLabelColor : .systemGreen
        pathLabel.set((project.path as NSString).abbreviatingWithTildeInPath)
        toolTip = project.isIdle ? "\(project.name) is idle" : project.name

        let ports = project.ports
        guard ports != shownPorts else { return }
        shownPorts = ports
        portStack.removeAllArrangedSubviews()
        let color = Theme.color(for: .projects)
        for port in ports.prefix(4) {
            portStack.addArrangedSubview(PillView(":\(port)", color: color))
        }
        if ports.count > 4 {
            portStack.addArrangedSubview(PillView("+\(ports.count - 4)", color: .secondaryLabelColor))
        }
    }

    private func makeMenu() -> NSMenu? {
        guard let project else { return nil }
        // The row can be reused for another project while the menu is open, so the items carry their own.
        let menu = NSMenu()
        let reveal = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = project
        menu.addItem(.separator())
        let stop = menu.addItem(withTitle: "Stop \(project.name)…", action: #selector(stopProject(_:)), keyEquivalent: "")
        stop.target = self
        stop.representedObject = project
        return menu
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? DevProject else { return }
        beforeModal()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    @objc private func stopProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? DevProject else { return }
        beforeModal()
        ProcessControl.stop(project.processes, title: "Stop \(project.name)?", window: nil) { _, _ in }
    }
}

// MARK: - Rows

/// A full-width row with a hover highlight, a click action and an optional context menu.
/// Subviews never receive mouse events, so the whole row acts as one target.
private class HoverRow: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// False for empty placeholder rows.
    var isActive = true {
        didSet { if !isActive { isHovered = false } }
    }
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    init(content: NSView, height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func resetHover(in view: NSView) {
        if let row = view as? HoverRow { row.isHovered = false }
        for subview in view.subviews { resetHover(in: subview) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered, isActive, onClick != nil else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, let superview else { return nil }
        return frame.contains(superview.convert(point, to: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { if isActive { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isActive, !event.modifierFlags.contains(.control),
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        isActive ? menuProvider?() : nil
    }
}

/// Overview row: symbol, name, figure with a short detail, and a sparkline.
private final class MetricRow: HoverRow {
    let titleLabel: NSTextField
    private let valueLabel = NSTextField.number("", size: 12, weight: .medium)
    private let detailLabel = NSTextField.number("", size: 11, color: .secondaryLabelColor)
    private let chart = ChartView(style: .sparkline)

    init(metric: Metric) {
        titleLabel = .label(metric.title, size: 12)
        let icon = NSImageView(image: NSImage.symbol(metric.symbolName, size: 12, weight: .medium) ?? NSImage())
        icon.contentTintColor = Theme.color(for: metric)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        chart.capacity = 60
        chart.widthAnchor.constraint(equalToConstant: 56).isActive = true
        chart.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let content = NSStackView.horizontal([icon, titleLabel, NSView.spacer(minWidth: 4), valueLabel, detailLabel, chart], spacing: 6)
        content.setCustomSpacing(4, after: valueLabel)
        content.setCustomSpacing(10, after: detailLabel)
        super.init(content: content, height: 30)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(value: String, detail: String, series: [ChartView.Series], maxValue: Double?) {
        valueLabel.set(value)
        detailLabel.set(detail)
        chart.maxValue = maxValue
        chart.series = series
    }
}

/// App icon, name and figure. Right click offers Quit and Force Quit.
private final class AppRow: HoverRow {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField.label("", size: 12)
    private let valueLabel = NSTextField.number("", size: 12, weight: .medium, color: .secondaryLabelColor)
    private var app: AppGroup?
    private var iconAppID: String?
    private let beforeModal: () -> Void

    init(metric: Metric, onOpen: @escaping (Metric) -> Void, beforeModal: @escaping () -> Void) {
        self.beforeModal = beforeModal
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        let content = NSStackView.horizontal([iconView, nameLabel, NSView.spacer(minWidth: 8), valueLabel], spacing: 7)
        super.init(content: content, height: 26)
        onClick = { onOpen(metric) }
        menuProvider = { [weak self] in self?.makeMenu() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ app: AppGroup?, value: String) {
        self.app = app
        isActive = app != nil
        alphaValue = app == nil ? 0 : 1
        guard let app else { return }
        if iconAppID != app.id {
            iconAppID = app.id
            iconView.image = AppIcons.icon(for: app)
        }
        nameLabel.set(app.name)
        valueLabel.set(value)
        let count = app.processes.count
        toolTip = count == 1 ? app.name : "\(app.name) · \(Format.processes(count))"
    }

    private func makeMenu() -> NSMenu? {
        guard let app else { return nil }
        // Rows are re-ranked on every sample, so the items carry the app they were built for.
        let menu = NSMenu()
        for (title, force) in [("Quit \(app.name)…", false), ("Force Quit \(app.name)…", true)] {
            let item = menu.addItem(withTitle: title, action: force ? #selector(forceQuitApp(_:)) : #selector(quitApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
        }
        return menu
    }

    @objc private func quitApp(_ sender: NSMenuItem) { quit(sender.representedObject as? AppGroup, force: false) }
    @objc private func forceQuitApp(_ sender: NSMenuItem) { quit(sender.representedObject as? AppGroup, force: true) }

    private func quit(_ app: AppGroup?, force: Bool) {
        guard let app else { return }
        beforeModal()
        ProcessControl.quit(app, force: force, window: nil)
    }
}

// MARK: - Small pieces

/// A caption above a list, inset to line up with the row contents.
private final class SectionHeader: NSStackView {
    init(_ title: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addArrangedSubview(NSTextField.caption(title))
        addArrangedSubview(NSView.spacer())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// One symbol in the tab row. The selected tab sits on a rounded background tinted with its color.
private final class TabButton: NSView {
    let metric: Metric
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            imageView.contentTintColor = isSelected ? Theme.color(for: metric) : .secondaryLabelColor
            setAccessibilitySelected(isSelected)
            needsDisplay = true
        }
    }
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private let imageView: NSImageView

    init(metric: Metric) {
        self.metric = metric
        imageView = NSImageView(image: NSImage.symbol(metric.symbolName, size: 13, weight: .medium) ?? NSImage())
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = metric.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(metric.title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func resetHover() { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        if isSelected {
            Theme.color(for: metric).withAlphaComponent(0.18).setFill()
            path.fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return frame.contains(superview.convert(point, to: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

private extension NSStackView {
    /// Adds a view that spans the stack's full width.
    func addFullWidth(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}
