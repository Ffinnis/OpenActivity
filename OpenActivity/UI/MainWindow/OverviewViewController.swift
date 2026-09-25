//
//  OverviewViewController.swift
//  OpenActivity
//
//  Every metric on one screen, plus where the memory and the power are going.
//

import AppKit

final class OverviewViewController: NSViewController, LivePage {
    var onOpen: ((Metric) -> Void)?

    private var updaters: [(SystemSnapshot) -> Void] = []
    private let machineLabel = NSTextField.label("", size: 20, weight: .bold)
    private let machineDetail = NSTextField.label("", size: 12, color: .secondaryLabelColor)
    private let idleBanner = CardView(frame: .zero)
    private let idleTitle = NSTextField.label("", size: 13, weight: .semibold)
    private let idleDetail = NSTextField.label("", size: 12, color: .secondaryLabelColor)
    private let alertsCard = CardView(frame: .zero)
    private let alertsList = NSStackView.vertical(spacing: 8)
    private var shownAlerts: [Date] = []
    private var alertTimeLabels: [(date: Date, label: NSTextField)] = []
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    override func loadView() {
        let page = NSStackView.vertical(spacing: Theme.cardSpacing, alignment: .leading)

        let header = NSStackView.vertical([machineLabel, machineDetail], spacing: 2)
        page.addArrangedSubview(header)

        let metrics = GridStack(columns: 3)
        metrics.setItems([cpuCard(), memoryCard(), gpuCard(), diskCard(), networkCard(), energyCard()])
        page.addArrangedSubview(metrics)

        buildIdleBanner()
        page.addArrangedSubview(idleBanner)

        let breakdowns = GridStack(columns: 3)
        breakdowns.setItems([memoryByTypeCard(), topAppsCard(title: "Memory by app", metric: .memory),
                             topAppsCard(title: "Power by app", metric: .battery)])
        page.addArrangedSubview(breakdowns)

        alertsCard.content.addArrangedSubview(CardHeader(title: "Recent alerts", symbol: "bell.badge", color: .systemOrange))
        alertsCard.content.addArrangedSubview(alertsList)
        alertsList.widthAnchor.constraint(equalTo: alertsCard.content.widthAnchor).isActive = true
        alertsCard.isHidden = true
        page.addArrangedSubview(alertsCard)

        for view in [metrics, idleBanner, breakdowns, alertsCard] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
        view = NSScrollView.page(with: page)
    }

    func update(with snapshot: SystemSnapshot) {
        machineLabel.set(snapshot.machineName)
        machineDetail.set("\(Monitor.productName) · \(snapshot.cpu.modelName) · \(Format.memory(snapshot.memory.total)) · up \(Format.duration(snapshot.uptime))")
        updaters.forEach { $0(snapshot) }
        updateIdleBanner(snapshot)
        updateAlerts()
    }

    // MARK: - Metric cards

    private func metricCard(_ metric: Metric, title: String, symbol: String, stats: [StatView],
                            chart: ChartView, update: @escaping (SystemSnapshot, BigFigureView, NSTextField) -> Void) -> CardView {
        let figure = BigFigureView(size: 28)
        let caption = NSTextField.caption()
        let statRow = NSStackView.horizontal(stats, spacing: 18, alignment: .top)
        let card = CardView([CardHeader(title: title, symbol: symbol, color: Theme.color(for: metric)),
                             NSStackView.vertical([figure, caption], spacing: 0), statRow, chart], spacing: 10)
        chart.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
        card.onClick = { [weak self] in self?.onOpen?(metric) }
        updaters.append { snapshot in update(snapshot, figure, caption) }
        return card
    }

    private func cpuCard() -> CardView {
        let user = StatView(title: "User", size: 13)
        let system = StatView(title: "System", size: 13)
        let load = StatView(title: "Load", size: 13)
        let chart = ChartView(style: .sparkline, height: 44)
        chart.maxValue = 1
        return metricCard(.cpu, title: "CPU", symbol: "cpu", stats: [user, system, load], chart: chart) { snapshot, figure, caption in
            figure.update(splitting: Format.percent(snapshot.cpu.total))
            caption.set(snapshot.cpu.modelName)
            user.update(Format.percent(snapshot.cpu.user))
            system.update(Format.percent(snapshot.cpu.system))
            load.update(String(format: "%.2f", snapshot.cpu.loadAverage.first ?? 0))
            chart.series = [.init(values: Monitor.shared.recent.cpu.values, color: Theme.color(for: .cpu))]
        }
    }

    private func memoryCard() -> CardView {
        let app = StatView(title: "App", size: 13)
        let wired = StatView(title: "Wired", size: 13)
        let compressed = StatView(title: "Compressed", size: 13)
        let chart = ChartView(style: .sparkline, height: 44)
        chart.maxValue = 1
        return metricCard(.memory, title: "Memory", symbol: "memorychip", stats: [app, wired, compressed], chart: chart) { snapshot, figure, caption in
            let memory = snapshot.memory
            figure.update(splitting: Format.memory(memory.used))
            caption.set("in use of \(Format.memory(memory.total)) · pressure \(memory.pressure.title.lowercased())")
            app.update(Format.memory(memory.app))
            wired.update(Format.memory(memory.wired))
            compressed.update(Format.memory(memory.compressed))
            chart.series = [.init(values: Monitor.shared.recent.memory.values, color: Theme.color(for: .memory))]
        }
    }

    private func gpuCard() -> CardView {
        let memory = StatView(title: "Memory", size: 13)
        let average = StatView(title: "Avg today", size: 13)
        let chart = ChartView(style: .sparkline, height: 44)
        chart.maxValue = 1
        var lastRead = Date.distantPast
        var cachedAverage: Double?
        return metricCard(.gpu, title: "GPU", symbol: "cube.transparent", stats: [memory, average], chart: chart) { snapshot, figure, caption in
            figure.update(splitting: Format.percent(snapshot.gpu.utilization))
            caption.set(snapshot.gpu.name)
            memory.update(Format.memory(snapshot.gpu.memoryInUse))
            if Date().timeIntervalSince(lastRead) > 60 {
                lastRead = Date()
                cachedAverage = HistoryStore.shared.average(.gpu, since: Calendar.current.startOfDay(for: Date()))
            }
            average.update(cachedAverage.map(Format.percent) ?? "–")
            chart.series = [.init(values: Monitor.shared.recent.gpu.values, color: Theme.color(for: .gpu))]
        }
    }

    private func diskCard() -> CardView {
        let reading = StatView(title: "Reading", size: 13)
        let writing = StatView(title: "Writing", size: 13)
        let chart = ChartView(style: .sparkline, height: 44)
        return metricCard(.disk, title: "Disk", symbol: "internaldrive", stats: [reading, writing], chart: chart) { snapshot, figure, caption in
            if let root = snapshot.disk.rootVolume {
                figure.update(splitting: Format.bytes(root.free))
                caption.set("free of \(Format.bytes(root.total))")
            }
            reading.update(Format.rate(snapshot.disk.readRate))
            writing.update(Format.rate(snapshot.disk.writeRate))
            let recent = Monitor.shared.recent
            chart.series = [
                .init(values: recent.diskRead.values, color: Theme.color(for: .disk)),
                .init(values: recent.diskWrite.values, color: Theme.secondaryColor(for: .disk), mirrored: true),
            ]
        }
    }

    private func networkCard() -> CardView {
        let up = StatView(title: "Uploading", size: 13)
        let today = StatView(title: "Today", size: 13)
        let chart = ChartView(style: .sparkline, height: 44)
        var lastRead = Date.distantPast
        var todayBytes: UInt64?
        return metricCard(.network, title: "Network", symbol: "network", stats: [up, today], chart: chart) { snapshot, figure, caption in
            figure.update(splitting: Format.rate(snapshot.network.inRate))
            caption.set("downloading" + (snapshot.network.interfaceKind.isEmpty ? "" : " · \(snapshot.network.interfaceKind)"))
            up.update(Format.rate(snapshot.network.outRate))
            if Date().timeIntervalSince(lastRead) > 30 {
                lastRead = Date()
                let totals = HistoryStore.shared.networkBytes(since: Calendar.current.startOfDay(for: Date()))
                todayBytes = totals.received + totals.sent
            }
            today.update(todayBytes.map { Format.bytes($0) } ?? "–")
            let recent = Monitor.shared.recent
            chart.series = [
                .init(values: recent.netIn.values, color: Theme.color(for: .network)),
                .init(values: recent.netOut.values, color: Theme.secondaryColor(for: .network), mirrored: true),
            ]
        }
    }

    private func energyCard() -> CardView {
        let first = StatView(title: "Remaining", size: 13)
        let second = StatView(title: "Power draw", size: 13)
        let third = StatView(title: "Health", size: 13)
        let chart = ChartView(style: .sparkline, height: 44)
        return metricCard(.battery, title: "Energy", symbol: "bolt.fill", stats: [first, second, third], chart: chart) { snapshot, figure, caption in
            let battery = snapshot.battery
            if battery.isPresent {
                figure.update(splitting: Format.percent(battery.charge))
                caption.set(battery.isCharging ? "charging" : battery.isPluggedIn ? "on power adapter" : "on battery")
                if let time = battery.timeRemaining, time > 0 {
                    first.titleLabel.set(battery.isCharging ? "Until full" : "Remaining")
                    first.update(Format.duration(time))
                } else {
                    first.titleLabel.set("Status")
                    first.update(battery.isFullyCharged ? "Charged" : battery.isPluggedIn ? "Plugged in" : "Estimating")
                }
                third.isHidden = false
                third.update(Format.percent(battery.health))
            } else {
                figure.update(splitting: Format.watts(battery.systemPower))
                caption.set("power draw")
                first.isHidden = true
                third.isHidden = true
            }
            second.update(Format.watts(battery.systemPower))
            chart.series = [.init(values: Monitor.shared.recent.power.values, color: Theme.color(for: .battery))]
        }
    }

    // MARK: - Breakdowns

    private func memoryByTypeCard() -> CardView {
        let bar = SegmentedBarView(height: 12)
        let header = CardHeader(title: "Memory by type", symbol: "chart.bar.fill", color: Theme.color(for: .memory))
        let rows = [
            LegendRow(name: "App", color: Theme.MemoryPart.app),
            LegendRow(name: "Wired", color: Theme.MemoryPart.wired),
            LegendRow(name: "Compressed", color: Theme.MemoryPart.compressed),
            LegendRow(name: "Cached", color: Theme.MemoryPart.cached),
            LegendRow(name: "Free", color: Theme.MemoryPart.free),
        ]
        let card = CardView([header, bar] + rows, spacing: 8)
        ([bar] + rows).forEach { $0.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true }
        card.onClick = { [weak self] in self?.onOpen?(.memory) }
        updaters.append { snapshot in
            let memory = snapshot.memory
            let values = [memory.app, memory.wired, memory.compressed, memory.cached, memory.free]
            let colors = [Theme.MemoryPart.app, Theme.MemoryPart.wired, Theme.MemoryPart.compressed, Theme.MemoryPart.cached, Theme.MemoryPart.free]
            bar.segments = zip(values, colors).map { .init(value: Double($0), color: $1) }
            for (row, value) in zip(rows, values) { row.valueLabel.set(Format.memory(value)) }
            header.accessoryLabel.set("\(Format.percent(memory.usedFraction)) in use")
        }
        return card
    }

    private func topAppsCard(title: String, metric: Metric) -> CardView {
        let palette: [NSColor] = [Theme.color(for: metric), .systemBlue, .systemOrange, .systemTeal, .tertiaryLabelColor]
        let header = CardHeader(title: title, symbol: metric == .memory ? "square.stack.3d.up.fill" : "bolt.fill", color: Theme.color(for: metric))
        let bar = SegmentedBarView(height: 12)
        let rows = palette.map { LegendRow(name: "–", color: $0) }
        let card = CardView([header, bar] + rows, spacing: 8)
        ([bar] + rows).forEach { $0.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true }
        card.onClick = { [weak self] in self?.onOpen?(metric) }

        updaters.append { snapshot in
            let apps = snapshot.apps.filter { !$0.isSystem || Preferences.shared.showSystemProcesses }
            let total = apps.reduce(0) { $0 + $1.value(for: metric) }
            let top = apps.sorted { $0.value(for: metric) > $1.value(for: metric) }.prefix(4)
            let other = max(0, total - top.reduce(0) { $0 + $1.value(for: metric) })
            let format: (Double) -> String = metric == .memory ? { Format.memory($0) } : { Format.watts($0) }
            header.accessoryLabel.set("\(format(total)) all apps")

            var segments: [SegmentedBarView.Segment] = []
            for (index, row) in rows.enumerated() {
                if index < top.count {
                    let app = top[top.index(top.startIndex, offsetBy: index)]
                    row.isHidden = false
                    row.nameLabel.set(app.name)
                    row.valueLabel.set(format(app.value(for: metric)))
                    segments.append(.init(value: app.value(for: metric), color: palette[index]))
                } else if index == rows.count - 1 {
                    row.nameLabel.set("Other")
                    row.valueLabel.set(format(other))
                    segments.append(.init(value: other, color: palette[index]))
                } else {
                    row.isHidden = true
                }
            }
            bar.segments = segments
        }
        return card
    }

    // MARK: - Idle dev servers

    private func buildIdleBanner() {
        let icon = NSImageView(image: NSImage.symbol("moon.zzz.fill", size: 18, color: .systemIndigo) ?? NSImage())
        let text = NSStackView.vertical([idleTitle, idleDetail], spacing: 2)
        let button = NSButton(title: "Review…", target: self, action: #selector(openProjects))
        button.bezelStyle = .rounded
        let row = NSStackView.horizontal([icon, text, NSView.spacer(), button], spacing: 12)
        idleBanner.content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: idleBanner.content.widthAnchor).isActive = true
        idleBanner.contentInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        idleBanner.isHidden = true
    }

    private func updateIdleBanner(_ snapshot: SystemSnapshot) {
        let idle = snapshot.projects.flatMap(\.processes).filter { $0.idleSince != nil && !$0.ports.isEmpty }
        idleBanner.isHidden = idle.isEmpty
        guard !idle.isEmpty else { return }
        let memory = idle.reduce(0) { $0 + $1.memory }
        let ports = idle.flatMap(\.ports).sorted().map(String.init).joined(separator: ", ")
        idleTitle.set(idle.count == 1 ? "A dev server has been idle for a while" : "\(idle.count) dev servers have been idle for a while")
        idleDetail.set("Stopping them would free \(Format.memory(memory)) and ports \(ports).")
    }

    @objc private func openProjects() {
        onOpen?(.projects)
    }

    // MARK: - Alerts

    private func updateAlerts() {
        let alerts = Array(AlertEngine.shared.recentAlerts.prefix(4))
        alertsCard.isHidden = alerts.isEmpty
        let dates = alerts.map(\.date)
        defer {
            for entry in alertTimeLabels {
                entry.label.set(relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
            }
        }
        guard dates != shownAlerts else { return }
        shownAlerts = dates
        alertsList.removeAllArrangedSubviews()
        alertTimeLabels.removeAll()
        for alert in alerts {
            let title = NSTextField.label(alert.title, size: 12, weight: .semibold)
            let body = NSTextField.label(alert.body, size: 12, color: .secondaryLabelColor)
            let time = NSTextField.label("", size: 11, color: .tertiaryLabelColor)
            alertTimeLabels.append((alert.date, time))
            let row = NSStackView.horizontal([NSStackView.vertical([title, body], spacing: 1), NSView.spacer(), time], spacing: 8)
            alertsList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: alertsList.widthAnchor).isActive = true
        }
    }
}
