//
//  MetricSummary.swift
//  OpenActivity
//
//  The row of cards at the top of each metric page.
//

import AppKit

final class MetricSummary {
    let view: GridStack
    private let metric: Metric
    private var updaters: [(SystemSnapshot) -> Void] = []
    private var lastHistoryRead = Date.distantPast
    private var historyCache: [String: Double] = [:]

    init(metric: Metric) {
        self.metric = metric
        view = GridStack(columns: 4)
        var cards: [NSView] = []
        switch metric {
        case .cpu: cards = cpuCards()
        case .memory: cards = memoryCards()
        case .disk: cards = diskCards()
        case .network: cards = networkCards()
        case .gpu: cards = gpuCards()
        default: cards = energyCards()
        }
        cards.append(topAppCard())
        view.setItems(cards)
    }

    func update(_ snapshot: SystemSnapshot) {
        refreshHistoryIfNeeded()
        updaters.forEach { $0(snapshot) }
    }

    // MARK: - History figures

    private func refreshHistoryIfNeeded() {
        guard Date().timeIntervalSince(lastHistoryRead) > 30 else { return }
        lastHistoryRead = Date()
        let store = HistoryStore.shared
        let today = Calendar.current.startOfDay(for: Date())
        switch metric {
        case .cpu:
            historyCache["avg"] = store.average(.cpu, since: today)
            historyCache["peak"] = store.peak(.cpu, since: today)
        case .gpu:
            historyCache["avg"] = store.average(.gpu, since: today)
            historyCache["peak"] = store.peak(.gpu, since: today)
        case .disk:
            historyCache["written"] = Double(store.diskBytesWritten(since: today))
        case .network:
            let dayTotals = store.networkBytes(since: today)
            let weekTotals = store.networkBytes(since: Date().addingTimeInterval(-7 * 86_400))
            let monthTotals = store.networkBytes(since: Date().addingTimeInterval(-30 * 86_400))
            historyCache["today"] = Double(dayTotals.received + dayTotals.sent)
            historyCache["week"] = Double(weekTotals.received + weekTotals.sent)
            historyCache["month"] = Double(monthTotals.received + monthTotals.sent)
        case .battery:
            historyCache["avgPower"] = store.average(.systemPower, since: today)
        default:
            break
        }
    }

    // MARK: - CPU

    private func cpuCards() -> [NSView] {
        let figure = BigFigureView()
        let user = StatView(title: "User", dot: Theme.color(for: .cpu))
        let system = StatView(title: "System", dot: Theme.secondaryColor(for: .cpu))
        let now = CardView([CardHeader(title: "Now", symbol: "cpu", color: Theme.color(for: .cpu)), figure,
                            NSStackView.horizontal([user, system], spacing: 20, alignment: .top)])

        let average = StatView(title: "Average today")
        let peak = StatView(title: "Peak today")
        let load = StatView(title: "Load average")
        let today = CardView([CardHeader(title: "Today", symbol: "clock", color: .secondaryLabelColor),
                              NSStackView.horizontal([average, peak], spacing: 20, alignment: .top), load])

        let coresHeader = CardHeader(title: "Cores", symbol: "square.grid.3x3.fill", color: .secondaryLabelColor)
        let bars = NSStackView.horizontal(spacing: 3, alignment: .bottom)
        bars.distribution = .fillEqually
        let coresCaption = NSTextField.caption()
        let cores = CardView([coresHeader, bars, coresCaption])
        bars.heightAnchor.constraint(equalToConstant: 52).isActive = true
        bars.widthAnchor.constraint(equalTo: cores.content.widthAnchor).isActive = true

        updaters.append { [weak self] snapshot in
            let cpu = snapshot.cpu
            figure.update(splitting: Format.percent(cpu.total))
            user.update(Format.percent(cpu.user))
            system.update(Format.percent(cpu.system))
            average.update(self?.historyCache["avg"].map(Format.percent) ?? "–")
            peak.update(self?.historyCache["peak"].map(Format.percent) ?? "–")
            load.update(cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "), detail: "1, 5 and 15 minutes")

            if bars.arrangedSubviews.count != cpu.perCore.count {
                bars.removeAllArrangedSubviews()
                for _ in cpu.perCore {
                    let meter = MeterView(height: nil)
                    meter.isVertical = true
                    bars.addArrangedSubview(meter)
                    meter.heightAnchor.constraint(equalTo: bars.heightAnchor).isActive = true
                }
            }
            for (index, load) in cpu.perCore.enumerated() {
                guard let meter = bars.arrangedSubviews[index] as? MeterView else { continue }
                meter.value = load
                meter.color = index < cpu.performanceCores ? Theme.color(for: .cpu) : .systemCyan
            }
            var caption = "\(cpu.logicalCores) cores"
            if cpu.efficiencyCores > 0 { caption += " · \(cpu.performanceCores)P + \(cpu.efficiencyCores)E" }
            coresCaption.set(caption)
            coresHeader.accessoryLabel.set(cpu.modelName)
        }
        return [now, today, cores]
    }

    // MARK: - Memory

    private func memoryCards() -> [NSView] {
        let figure = BigFigureView()
        let ofTotal = NSTextField.caption()
        let pressure = PillView("Normal", color: .systemGreen, monospaced: false)
        let inUse = CardView([CardHeader(title: "In use", symbol: "memorychip", color: Theme.color(for: .memory)),
                              figure, NSStackView.horizontal([ofTotal, pressure], spacing: 8)])

        let bar = SegmentedBarView(height: 10)
        let app = LegendRow(name: "App", color: Theme.MemoryPart.app)
        let wired = LegendRow(name: "Wired", color: Theme.MemoryPart.wired)
        let compressed = LegendRow(name: "Compressed", color: Theme.MemoryPart.compressed)
        let cached = LegendRow(name: "Cached", color: Theme.MemoryPart.cached)
        let free = LegendRow(name: "Free", color: Theme.MemoryPart.free)
        let byTypeHeader = CardHeader(title: "By type", symbol: "chart.bar.fill", color: .secondaryLabelColor)
        let byType = CardView([byTypeHeader, bar, app, wired, compressed, cached, free], spacing: 6)
        for view in [bar, app, wired, compressed, cached, free] {
            view.widthAnchor.constraint(equalTo: byType.content.widthAnchor).isActive = true
        }

        let swap = StatView(title: "Swap used")
        let cachedStat = StatView(title: "Cached files")
        let swapCard = CardView([CardHeader(title: "Swap", symbol: "arrow.left.arrow.right", color: .secondaryLabelColor), swap, cachedStat])

        updaters.append { snapshot in
            let memory = snapshot.memory
            figure.update(splitting: Format.memory(memory.used))
            ofTotal.set("of \(Format.memory(memory.total))")
            pressure.label.set(memory.pressure.title)
            pressure.color = memory.pressure == .normal ? .systemGreen : memory.pressure == .warning ? .systemOrange : .systemRed
            bar.segments = [
                .init(value: Double(memory.app), color: Theme.MemoryPart.app),
                .init(value: Double(memory.wired), color: Theme.MemoryPart.wired),
                .init(value: Double(memory.compressed), color: Theme.MemoryPart.compressed),
                .init(value: Double(memory.cached), color: Theme.MemoryPart.cached),
                .init(value: Double(memory.free), color: Theme.MemoryPart.free),
            ]
            app.valueLabel.set(Format.memory(memory.app))
            wired.valueLabel.set(Format.memory(memory.wired))
            compressed.valueLabel.set(Format.memory(memory.compressed))
            cached.valueLabel.set(Format.memory(memory.cached))
            free.valueLabel.set(Format.memory(memory.free))
            byTypeHeader.accessoryLabel.set("\(Format.percent(memory.usedFraction)) in use")
            swap.update(Format.memory(memory.swapUsed), detail: memory.swapTotal > 0 ? "of \(Format.memory(memory.swapTotal)) allocated" : "No swap file in use")
            cachedStat.update(Format.memory(memory.cached), detail: "Handed back as soon as apps need it")
        }
        return [inUse, byType, swapCard]
    }

    // MARK: - Disk

    private func diskCards() -> [NSView] {
        let figure = BigFigureView()
        let ofTotal = NSTextField.caption()
        let usage = SegmentedBarView(height: 8)
        let freeCard = CardView([CardHeader(title: "Free", symbol: "internaldrive", color: Theme.color(for: .disk)), figure, ofTotal, usage])
        usage.widthAnchor.constraint(equalTo: freeCard.content.widthAnchor).isActive = true

        let reading = StatView(title: "Reading", dot: Theme.color(for: .disk))
        let writing = StatView(title: "Writing", dot: Theme.secondaryColor(for: .disk))
        let written = StatView(title: "Written today")
        let activity = CardView([CardHeader(title: "Activity", symbol: "arrow.up.arrow.down", color: .secondaryLabelColor),
                                 NSStackView.horizontal([reading, writing], spacing: 20, alignment: .top), written])

        let volumesHeader = CardHeader(title: "Volumes", symbol: "externaldrive", color: .secondaryLabelColor)
        let volumeList = NSStackView.vertical(spacing: 8)
        let volumes = CardView([volumesHeader, volumeList])
        volumeList.widthAnchor.constraint(equalTo: volumes.content.widthAnchor).isActive = true
        var shownVolumes: [String] = []

        updaters.append { [weak self] snapshot in
            let disk = snapshot.disk
            if let root = disk.rootVolume {
                figure.update(splitting: Format.bytes(root.free))
                ofTotal.set("of \(Format.bytes(root.total)) · \(Format.bytes(root.used)) used")
                usage.segments = [.init(value: Double(root.used), color: Theme.color(for: .disk))]
                usage.total = Double(root.total)
            }
            reading.update(Format.rate(disk.readRate))
            writing.update(Format.rate(disk.writeRate))
            written.update(self?.historyCache["written"].map { Format.bytes($0) } ?? "–", detail: "Across all apps")
            volumesHeader.accessoryLabel.set("\(disk.volumes.count)")

            let paths = disk.volumes.map(\.path)
            if paths != shownVolumes {
                shownVolumes = paths
                volumeList.removeAllArrangedSubviews()
                for volume in disk.volumes {
                    let name = NSTextField.label(volume.name, size: 12, weight: .medium)
                    let free = NSTextField.number("", size: 11, color: .secondaryLabelColor)
                    free.identifier = .init(volume.path)
                    let meter = MeterView(height: 5)
                    meter.color = Theme.color(for: .disk)
                    let row = NSStackView.vertical([NSStackView.horizontal([name, NSView.spacer(), free]), meter], spacing: 4)
                    volumeList.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: volumeList.widthAnchor).isActive = true
                    row.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
                }
            }
            for (row, volume) in zip(volumeList.arrangedSubviews.compactMap { $0 as? NSStackView }, disk.volumes) {
                let header = row.arrangedSubviews.first as? NSStackView
                (header?.arrangedSubviews.last as? NSTextField)?.set("\(Format.bytes(volume.free)) free")
                (row.arrangedSubviews.last as? MeterView)?.value = volume.total > 0 ? Double(volume.used) / Double(volume.total) : 0
            }
        }
        return [freeCard, activity, volumes]
    }

    // MARK: - Network

    private func networkCards() -> [NSView] {
        let down = BigFigureView()
        let up = StatView(title: "Uploading", dot: Theme.secondaryColor(for: .network))
        let downCaption = NSStackView.horizontal([DotView(color: Theme.color(for: .network)), NSTextField.caption("Downloading")], spacing: 5)
        let now = CardView([CardHeader(title: "Now", symbol: "network", color: Theme.color(for: .network)), downCaption, down, up])

        let today = StatView(title: "Today")
        let week = StatView(title: "Last 7 days")
        let month = StatView(title: "Last 30 days")
        let totals = CardView([CardHeader(title: "Transferred", symbol: "calendar", color: .secondaryLabelColor),
                               today, NSStackView.horizontal([week, month], spacing: 20, alignment: .top)])

        let kind = StatView(title: "Interface")
        let address = StatView(title: "Local address")
        let interface = CardView([CardHeader(title: "Connection", symbol: "wifi", color: .secondaryLabelColor), kind, address])

        updaters.append { [weak self] snapshot in
            let network = snapshot.network
            down.update(splitting: Format.rate(network.inRate))
            up.update(Format.rate(network.outRate))
            today.update(self?.historyCache["today"].map { Format.bytes($0) } ?? "–", detail: "Down and up combined")
            week.update(self?.historyCache["week"].map { Format.bytes($0) } ?? "–")
            month.update(self?.historyCache["month"].map { Format.bytes($0) } ?? "–")
            kind.update(network.interfaceKind.isEmpty ? "Not connected" : network.interfaceKind, detail: network.interfaceName.isEmpty ? nil : network.interfaceName)
            address.update(network.localAddress ?? "–")
        }
        return [now, totals, interface]
    }

    // MARK: - GPU

    private func gpuCards() -> [NSView] {
        let figure = BigFigureView()
        let name = NSTextField.caption()
        let now = CardView([CardHeader(title: "Now", symbol: "cube.transparent", color: Theme.color(for: .gpu)), figure, name])

        let memory = StatView(title: "Memory in use")
        let memoryCard = CardView([CardHeader(title: "Memory", symbol: "memorychip", color: .secondaryLabelColor), memory])

        let average = StatView(title: "Average today")
        let peak = StatView(title: "Peak today")
        let today = CardView([CardHeader(title: "Today", symbol: "clock", color: .secondaryLabelColor), average, peak])

        updaters.append { [weak self] snapshot in
            let gpu = snapshot.gpu
            figure.update(splitting: Format.percent(gpu.utilization))
            name.set(gpu.name + (gpu.coreCount.map { " · \($0) cores" } ?? ""))
            memory.update(Format.memory(gpu.memoryInUse), detail: "Shared with the rest of the system")
            average.update(self?.historyCache["avg"].map(Format.percent) ?? "–")
            peak.update(self?.historyCache["peak"].map(Format.percent) ?? "–")
        }
        return [now, memoryCard, today]
    }

    // MARK: - Energy

    private func energyCards() -> [NSView] {
        let ring = RingView(diameter: 64)
        ring.color = Theme.color(for: .battery)
        let state = NSTextField.label("", size: 13, weight: .semibold)
        let remaining = NSTextField.caption()
        let batteryCard = CardView([CardHeader(title: "Battery", symbol: "battery.100percent", color: Theme.color(for: .battery)),
                                    NSStackView.horizontal([ring, NSStackView.vertical([state, remaining], spacing: 3)], spacing: 14)])

        let draw = BigFigureView()
        let adapter = NSTextField.caption()
        let average = StatView(title: "Average today")
        let power = CardView([CardHeader(title: "Power draw", symbol: "bolt", color: .secondaryLabelColor), draw, adapter, average])

        let health = StatView(title: "Maximum capacity")
        let cycles = StatView(title: "Cycle count")
        let temperature = StatView(title: "Temperature")
        let healthCard = CardView([CardHeader(title: "Health", symbol: "heart", color: .secondaryLabelColor),
                                   health, NSStackView.horizontal([cycles, temperature], spacing: 20, alignment: .top)])

        updaters.append { [weak self] snapshot in
            let battery = snapshot.battery
            batteryCard.isHidden = !battery.isPresent
            healthCard.isHidden = !battery.isPresent
            ring.value = battery.charge
            ring.label.set(Format.percent(battery.charge))
            ring.color = battery.charge < 0.2 && !battery.isPluggedIn ? .systemRed : Theme.color(for: .battery)
            if battery.isFullyCharged || (battery.isPluggedIn && !battery.isCharging) {
                state.set(battery.isFullyCharged ? "Charged" : "Plugged in, not charging")
            } else {
                state.set(battery.isCharging ? "Charging" : "On battery")
            }
            if let time = battery.timeRemaining, time > 0 {
                remaining.set(battery.isCharging ? "Full in \(Format.duration(time))" : "\(Format.duration(time)) remaining")
            } else {
                remaining.set(battery.isPluggedIn ? "Power adapter connected" : "Estimating time left…")
            }
            draw.update(splitting: Format.watts(battery.systemPower))
            adapter.set(battery.adapterWatts.map { "\(Int($0)) W adapter" } ?? (battery.isPluggedIn ? "On power adapter" : "From the battery"))
            average.update(self?.historyCache["avgPower"].map(Format.watts) ?? "–")
            health.update(Format.percent(battery.health), detail: battery.condition)
            cycles.update(Format.number(battery.cycleCount))
            temperature.update(Format.temperature(battery.temperature))
        }
        return [batteryCard, power, healthCard]
    }

    // MARK: - Top app

    private func topAppCard() -> NSView {
        let header = CardHeader(title: "Top app", symbol: "crown", color: .secondaryLabelColor)
        let icon = NSImageView()
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let name = NSTextField.label("–", size: 14, weight: .semibold)
        let value = NSTextField.number("", size: 13, weight: .medium, color: Theme.color(for: metric))
        let detail = NSTextField.caption()
        let card = CardView([header, NSStackView.horizontal([icon, NSStackView.vertical([name, value], spacing: 2)], spacing: 10), detail])
        let metric = self.metric

        updaters.append { snapshot in
            let candidates = snapshot.apps.filter { !$0.isSystem || Preferences.shared.showSystemProcesses }
            guard let top = candidates.max(by: { $0.value(for: metric) < $1.value(for: metric) }), top.value(for: metric) > 0 else {
                name.set("Nothing busy")
                value.set("")
                icon.image = nil
                detail.set("")
                return
            }
            icon.image = AppIcons.icon(for: top)
            name.set(top.name)
            value.set(Self.appFigure(top, metric: metric))
            detail.set(Format.processes(top.processes.count))
        }
        return card
    }

    static func appFigure(_ app: AppGroup, metric: Metric) -> String {
        switch metric {
        case .cpu: return Format.cpu(app.cpuPercent)
        case .memory: return Format.memory(app.memory)
        case .disk: return Format.rate(app.diskReadRate + app.diskWriteRate)
        case .network: return "↓ \(Format.rate(app.netInRate))  ↑ \(Format.rate(app.netOutRate))"
        case .gpu: return String(format: "%.1f%%", app.gpuPercent)
        default: return Format.watts(app.power)
        }
    }
}
