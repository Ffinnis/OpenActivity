//
//  MetricPageViewController.swift
//  OpenActivity
//
//  CPU, Memory, Disk, Network, GPU and Energy pages: summary cards and a chart on top,
//  the apps behind the figure below.
//

import AppKit

final class MetricPageViewController: NSViewController, LivePage, NSSplitViewDelegate {
    let metric: Metric
    private let table: AppTableController
    private let summary: MetricSummary
    private let chart: HistoryChartCard
    private let tableTitle = NSTextField.label("Apps", size: 13, weight: .semibold)
    private let tableCount = NSTextField.caption()
    private let systemToggle = NSButton(checkboxWithTitle: "Show macOS processes", target: nil, action: nil)

    init(metric: Metric) {
        self.metric = metric
        table = AppTableController(metric: metric)
        summary = MetricSummary(metric: metric)
        chart = HistoryChartCard(metric: metric)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let top = NSStackView.vertical([summary.view, chart], spacing: Theme.cardSpacing, alignment: .leading)
        summary.view.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        chart.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        let topScroll = NSScrollView.page(with: top, insets: NSEdgeInsets(top: 12, left: Theme.pagePadding, bottom: 10, right: Theme.pagePadding))
        topContent = top

        systemToggle.target = self
        systemToggle.action = #selector(toggleSystem(_:))
        systemToggle.controlSize = .small
        systemToggle.font = .systemFont(ofSize: 11)
        let header = NSStackView.horizontal([tableTitle, tableCount, NSView.spacer(), systemToggle], spacing: 8)
        header.translatesAutoresizingMaskIntoConstraints = false

        let bottom = NSView()
        bottom.addSubview(header)
        bottom.addSubview(table.scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: bottom.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: Theme.pagePadding),
            header.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -Theme.pagePadding),
            table.scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            table.scrollView.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 8),
            table.scrollView.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -8),
            table.scrollView.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
        ])

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(topScroll)
        split.addArrangedSubview(bottom)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        view = split
    }

    /// Runs once, after the first snapshot fills the summary (before that, captions and lists that
    /// are still hidden or empty would make the content measure short).
    private func positionDividerIfNeeded() {
        guard let split = view as? NSSplitView, let topContent, !didPositionDivider,
              view.window != nil, view.bounds.height > 0 else { return }
        didPositionDivider = true
        view.layoutSubtreeIfNeeded()
        // Show the summary and the whole chart, keeping at least 200 pt for the table. The top pane
        // sits under the toolbar, so its scroll view's top inset counts too.
        let window = split.window
        let toolbarInset = max(0, (window?.contentView?.bounds.height ?? 0) - (window?.contentLayoutRect.height ?? 0))
        let wanted = topContent.fittingSize.height + 22 + toolbarInset
        split.setPosition(min(wanted, view.bounds.height - 200), ofDividerAt: 0)
    }
    private var didPositionDivider = false
    private weak var topContent: NSView?

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - 160
    }

    func update(with snapshot: SystemSnapshot) {
        summary.update(snapshot)
        chart.updateLive()
        table.update(apps: snapshot.apps, memoryTotal: snapshot.memory.total)
        systemToggle.state = Preferences.shared.showSystemProcesses ? .on : .off
        let apps = Preferences.shared.showSystemProcesses ? snapshot.apps.count : snapshot.apps.filter { !$0.isSystem }.count
        tableCount.set("\(apps) apps · \(Format.processes(snapshot.processCount))")
        positionDividerIfNeeded()
    }

    func applySearch(_ text: String) {
        table.setSearch(text)
    }

    @objc private func toggleSystem(_ sender: NSButton) {
        Preferences.shared.showSystemProcesses = sender.state == .on
    }
}

// MARK: - Chart card

/// A chart with a range picker: live samples or the stored history.
final class HistoryChartCard: CardView {
    private let metric: Metric
    private let chartView = ChartView(style: .full, height: 190)
    private let rangeControl: NSSegmentedControl
    private let legend = NSStackView.horizontal(spacing: 14)
    private let topList = NSStackView.vertical(spacing: 6)
    private let topBox: NSStackView
    private var range: HistoryRange?
    private var lastHistoryLoad = Date.distantPast

    private static let ranges: [HistoryRange?] = [nil] + HistoryRange.allCases.map(Optional.some)

    init(metric: Metric) {
        self.metric = metric
        rangeControl = NSSegmentedControl(labels: Self.ranges.map { $0?.title ?? "Live" }, trackingMode: .selectOne, target: nil, action: nil)
        topBox = NSStackView.vertical([], spacing: 8)
        super.init(frame: .zero)

        rangeControl.selectedSegment = 0
        rangeControl.controlSize = .small
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged(_:))

        let title = NSTextField.label(Self.title(for: metric), size: 13, weight: .semibold)
        let header = NSStackView.horizontal([title, legend, NSView.spacer(), rangeControl], spacing: 12)

        let topTitle = NSTextField.caption("Most over this period")
        topBox.addArrangedSubview(topTitle)
        topBox.addArrangedSubview(topList)
        topBox.isHidden = true
        topBox.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let body = NSStackView.horizontal([chartView, topBox], spacing: 20, alignment: .top)
        content.addArrangedSubview(header)
        content.addArrangedSubview(body)
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        chartView.valueFormatter = Self.formatter(for: metric)
        chartView.maxValue = Self.fixedMax(for: metric)
        for (name, color) in Self.legend(for: metric) {
            legend.addArrangedSubview(NSStackView.horizontal([DotView(color: color), NSTextField.label(name, size: 11, color: .secondaryLabelColor)], spacing: 5))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func title(for metric: Metric) -> String {
        switch metric {
        case .cpu: return "CPU Load"
        case .memory: return "Memory Used"
        case .disk: return "Disk Activity"
        case .network: return "Network Traffic"
        case .gpu: return "GPU Load"
        default: return "Power Draw"
        }
    }

    private static func legend(for metric: Metric) -> [(String, NSColor)] {
        switch metric {
        case .cpu: return [("Total", Theme.color(for: .cpu)), ("System", Theme.secondaryColor(for: .cpu))]
        case .disk: return [("Read", Theme.color(for: .disk)), ("Write", Theme.secondaryColor(for: .disk))]
        case .network: return [("Down", Theme.color(for: .network)), ("Up", Theme.secondaryColor(for: .network))]
        default: return []
        }
    }

    private static func formatter(for metric: Metric) -> (Double) -> String {
        switch metric {
        case .disk, .network: return { Format.rate($0) }
        case .battery: return { Format.watts($0) }
        default: return { Format.percent($0) }
        }
    }

    private static func fixedMax(for metric: Metric) -> Double? {
        switch metric {
        case .cpu, .memory, .gpu: return 1
        default: return nil
        }
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        range = Self.ranges[sender.selectedSegment]
        lastHistoryLoad = .distantPast
        topBox.isHidden = range == nil
        updateLive()
    }

    /// Called on every snapshot: redraws live data, reloads history at most once a minute.
    func updateLive() {
        if let range {
            guard Date().timeIntervalSince(lastHistoryLoad) > 60 else { return }
            lastHistoryLoad = Date()
            loadHistory(range)
            return
        }
        let recent = Monitor.shared.recent
        let primary = Theme.color(for: metric)
        let secondary = Theme.secondaryColor(for: metric)
        chartView.timeRange = nil
        chartView.emptyText = "Collecting samples…"
        switch metric {
        case .cpu:
            chartView.series = [
                .init(values: recent.cpu.values, color: primary, name: "Total"),
                .init(values: recent.cpuSystem.values, color: secondary, name: "System"),
            ]
        case .memory:
            chartView.series = [.init(values: recent.memory.values, color: primary)]
        case .disk:
            chartView.series = [
                .init(values: recent.diskRead.values, color: primary, name: "Read"),
                .init(values: recent.diskWrite.values, color: secondary, name: "Write", mirrored: true),
            ]
        case .network:
            chartView.series = [
                .init(values: recent.netIn.values, color: primary, name: "Down"),
                .init(values: recent.netOut.values, color: secondary, name: "Up", mirrored: true),
            ]
        case .gpu:
            chartView.series = [.init(values: recent.gpu.values, color: primary)]
        default:
            chartView.series = [.init(values: recent.power.values, color: primary)]
        }
    }

    private func loadHistory(_ range: HistoryRange) {
        let store = HistoryStore.shared
        let primary = Theme.color(for: metric)
        let secondary = Theme.secondaryColor(for: metric)
        func points(_ series: HistorySeries) -> [(date: Date, value: Double)] {
            store.series(series, range: range).map { ($0.date, $0.value) }
        }
        var series: [ChartView.TimedSeries]
        switch metric {
        case .cpu: series = [.init(points: points(.cpu), color: primary, name: "CPU")]
        case .memory:
            let total = Double(max(1, Monitor.shared.snapshot.memory.total))
            series = [.init(points: points(.memoryUsed).map { ($0.date, $0.value / total) }, color: primary, name: "Used")]
        case .disk: series = [.init(points: points(.diskRead), color: primary, name: "Read"), .init(points: points(.diskWrite), color: secondary, name: "Write")]
        case .network: series = [.init(points: points(.netIn), color: primary, name: "Down"), .init(points: points(.netOut), color: secondary, name: "Up")]
        case .gpu: series = [.init(points: points(.gpu), color: primary, name: "GPU")]
        default: series = [.init(points: points(.systemPower), color: primary, name: "Power")]
        }
        let now = Date()
        chartView.emptyText = "No history for this period yet"
        chartView.timedSeries = series
        chartView.timeRange = now.addingTimeInterval(-range.duration)...now

        topList.removeAllArrangedSubviews()
        let top = store.topApps(by: metric, range: range, limit: 6)
        if top.isEmpty {
            topList.addArrangedSubview(NSTextField.label("Nothing recorded yet", size: 12, color: .tertiaryLabelColor))
        }
        for app in top {
            let icon = NSImageView(image: AppIcons.icon(bundlePath: app.bundlePath, isSystem: app.appID == AppGrouper.systemGroupID))
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let name = NSTextField.label(app.name, size: 12)
            let value = NSTextField.number(Self.historyValue(app.value, metric: metric), size: 12, weight: .medium, color: .secondaryLabelColor)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = NSStackView.horizontal([icon, name, NSView.spacer(), value], spacing: 6)
            topList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: topList.widthAnchor).isActive = true
        }
    }

    /// Averages for rates and loads, totals for disk and network.
    static func historyValue(_ value: Double, metric: Metric) -> String {
        switch metric {
        case .cpu: return Format.cpu(value)
        case .memory: return Format.memory(value)
        case .disk, .network: return Format.bytes(value)
        case .gpu: return String(format: "%.1f%%", value)
        default: return Format.watts(value)
        }
    }
}
