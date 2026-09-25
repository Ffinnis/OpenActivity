//
//  SettingsWindowController.swift
//  OpenActivity
//
//  The Settings window: a toolbar of panes (General, Menu Bar, Alerts, History, About).
//  Each pane is a two-column form; the window animates its height to fit the selected pane.
//

import AppKit
import UserNotifications

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let tabs = SettingsTabViewController()
    private var hasBeenShown = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsPane.width, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.contentViewController = tabs
        super.init(window: window)
        window.delegate = self
        tabs.fitWindow(animated: false)
    }

    func windowWillClose(_ notification: Notification) {
        // Ends any edit in progress so a typed threshold is saved.
        window?.makeFirstResponder(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        if !hasBeenShown {
            window.center()
            hasBeenShown = true
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Tabs

private final class SettingsTabViewController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        // No crossfade: during one the window keeps the old pane's height, leaving a gap under a shorter pane.
        transitionOptions = [.allowUserInteraction]
        let panes: [(SettingsPane, String)] = [
            (GeneralPane(), "gearshape"),
            (MenuBarPane(), "menubar.rectangle"),
            (AlertsPane(), "bell.badge"),
            (HistoryPane(), "clock.arrow.circlepath"),
            (AboutPane(), "info.circle"),
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: true)
    }

    /// Titles the window after the selected pane and resizes it to the pane, keeping the top edge in place.
    func fitWindow(animated: Bool) {
        guard let window = view.window,
              selectedTabViewItemIndex >= 0,
              let pane = tabViewItems[selectedTabViewItemIndex].viewController else { return }
        window.title = pane.title ?? ""
        let size = pane.view.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }
}

// MARK: - Pane base

/// A settings pane: a form of right-aligned labels and controls with 20 pt margins.
private class SettingsPane: NSViewController {
    static let width: CGFloat = 560
    static let labelColumnWidth: CGFloat = 150
    static let margin: CGFloat = 20
    static let columnSpacing: CGFloat = 8
    /// Width available to the control column, used to wrap explanations.
    static var controlColumnWidth: CGFloat { width - 2 * margin - labelColumnWidth - columnSpacing }

    let grid: NSGridView = {
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = SettingsPane.columnSpacing
        grid.rowAlignment = .firstBaseline
        return grid
    }()

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let view = NSView()
        buildForm()
        if grid.numberOfColumns == 2 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = Self.labelColumnWidth
        }
        view.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        let width = view.widthAnchor.constraint(equalToConstant: Self.width)
        width.priority = .init(999)
        NSLayoutConstraint.activate([
            width,
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.margin),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.margin),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Self.margin),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -Self.margin),
        ])
        self.view = view
        // NSTabViewController sizes the window from this when the pane is selected.
        preferredContentSize = view.fittingSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = view.fittingSize
    }

    /// Subclasses add their rows here.
    func buildForm() {}

    // MARK: Row helpers

    @discardableResult
    func addRow(_ label: String?, _ content: NSView, topPadding: CGFloat = 0) -> NSGridRow {
        let labelView: NSView
        if let label {
            let field = NSTextField(labelWithString: label)
            field.alignment = .right
            labelView = field
        } else {
            labelView = NSGridCell.emptyContentView
        }
        let row = grid.addRow(with: [labelView, content])
        row.topPadding = topPadding
        return row
    }

    /// A small explanatory note under a control, indented to line up with checkbox titles.
    @discardableResult
    func addNote(_ text: String, indented: Bool = true, topPadding: CGFloat = -4) -> NSTextField {
        let indent = indented ? Self.checkboxIndent : 0
        let note = Self.note(text, width: Self.controlColumnWidth - indent)
        let container = NSView()
        container.addSubview(note)
        note.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
            note.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            note.topAnchor.constraint(equalTo: container.topAnchor),
            note.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        addRow(nil, container, topPadding: topPadding).rowAlignment = .none
        return note
    }

    /// Checkbox image plus the gap before its title.
    static let checkboxIndent: CGFloat = 20

    static func note(_ text: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    func checkbox(_ title: String, action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }
}

// MARK: - General

private final class GeneralPane: SettingsPane {
    private var launchAtLogin: NSButton!
    private var dockIcon: NSButton!
    private var systemProcesses: NSButton!

    init() { super.init(title: "General") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func buildForm() {
        launchAtLogin = checkbox("Open OpenActivity when you log in", action: #selector(toggleLaunchAtLogin(_:)))
        dockIcon = checkbox("Show icon in the Dock", action: #selector(toggleDockIcon(_:)))
        systemProcesses = checkbox("Show macOS system processes in app lists", action: #selector(toggleSystemProcesses(_:)))

        addRow("Startup:", launchAtLogin)
        addRow("Dock:", dockIcon, topPadding: 6)
        addNote("With the icon hidden, OpenActivity keeps running in the menu bar. Open the main window from there.")
        addRow("App lists:", systemProcesses, topPadding: 6)
        addNote("Daemons and background services that belong to macOS are shown together as one “macOS” entry.")

        let helper = Self.note("""
            Not installed. macOS only reports figures for processes that run under your account, \
            so processes owned by root appear in lists without CPU, memory or disk figures.
            """, width: Self.controlColumnWidth)
        helper.font = .systemFont(ofSize: NSFont.systemFontSize)
        addRow("Optional helper:", helper, topPadding: 14)

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Preferences.didChange, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    @objc private func refresh() {
        let preferences = Preferences.shared
        launchAtLogin.state = preferences.launchAtLogin ? .on : .off
        dockIcon.state = preferences.showDockIcon ? .on : .off
        systemProcesses.state = preferences.showSystemProcesses ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        Preferences.shared.launchAtLogin = sender.state == .on
        // Registration can fail or need approval; show what macOS actually did.
        refresh()
    }

    @objc private func toggleDockIcon(_ sender: NSButton) {
        Preferences.shared.showDockIcon = sender.state == .on
        // Switching the activation policy can drop the window behind others.
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func toggleSystemProcesses(_ sender: NSButton) {
        Preferences.shared.showSystemProcesses = sender.state == .on
    }
}

// MARK: - Menu Bar

private final class MenuBarPane: SettingsPane {
    private var stylePicker: NSSegmentedControl!
    private let preview = MenuBarPreview()
    private var styleNote: NSTextField!
    private var metricBoxes: [(Metric, NSButton)] = []

    init() { super.init(title: "Menu Bar") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func title(for metric: Metric) -> String {
        switch metric {
        case .sensors: return "CPU temperature"
        case .battery: return "Battery"
        default: return metric.title
        }
    }

    private static func explanation(for style: MenuBarStyle) -> String {
        switch style {
        case .icon: return "A single symbol and nothing else. The most compact choice."
        case .figure: return "The current value of each figure you pick below, side by side."
        case .graph: return "A tiny live graph for each figure, so you can spot spikes at a glance."
        case .stacked: return "Figures in two small lines, which fits more into less space."
        }
    }

    override func buildForm() {
        stylePicker = NSSegmentedControl(labels: MenuBarStyle.allCases.map(\.title), trackingMode: .selectOne,
                                         target: self, action: #selector(changeStyle(_:)))
        stylePicker.segmentDistribution = .fillEqually
        stylePicker.widthAnchor.constraint(equalToConstant: 300).isActive = true
        addRow("Style:", stylePicker)

        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 300),
            preview.heightAnchor.constraint(equalToConstant: 30),
        ])
        addRow(nil, preview).rowAlignment = .none
        styleNote = addNote("", indented: false, topPadding: -2)

        for (index, metric) in Preferences.menuBarChoices.enumerated() {
            let box = checkbox(Self.title(for: metric), action: #selector(toggleMetric(_:)))
            metricBoxes.append((metric, box))
            addRow(index == 0 ? "Show:" : nil, box, topPadding: index == 0 ? 10 : -4)
        }
        addNote("Used by the Figure, Graph and Stacked styles, in the order listed here.")

        let warning = Self.note("""
            In every style, the menu bar icon turns into a warning sign while your Mac is under strain, \
            for example when memory runs short or an app keeps the processor busy.
            """, width: Self.controlColumnWidth)
        warning.font = .systemFont(ofSize: NSFont.systemFontSize)
        addRow("Warnings:", warning, topPadding: 10)

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Preferences.didChange, object: nil)
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    @objc private func refresh() {
        let preferences = Preferences.shared
        let style = preferences.menuBarStyle
        stylePicker.selectedSegment = MenuBarStyle.allCases.firstIndex(of: style) ?? 0
        styleNote.stringValue = Self.explanation(for: style)
        let chosen = Set(preferences.menuBarMetrics)
        for (metric, box) in metricBoxes {
            box.state = chosen.contains(metric) ? .on : .off
            box.isEnabled = style != .icon
        }
        preview.style = style
        preview.metrics = preferences.menuBarMetrics
    }

    @objc private func changeStyle(_ sender: NSSegmentedControl) {
        guard MenuBarStyle.allCases.indices.contains(sender.selectedSegment) else { return }
        Preferences.shared.menuBarStyle = MenuBarStyle.allCases[sender.selectedSegment]
    }

    @objc private func toggleMetric(_ sender: NSButton) {
        let chosen = metricBoxes.filter { $0.1.state == .on }.map(\.0)
        if chosen.isEmpty {
            // Keep at least one figure; an empty status item would disappear.
            sender.state = .on
            NSSound.beep()
            return
        }
        Preferences.shared.menuBarMetrics = chosen
    }
}

/// Draws a strip of menu bar with the chosen style, using sample values or the latest snapshot.
private final class MenuBarPreview: NSView {
    var style: MenuBarStyle = .figure { didSet { needsDisplay = true } }
    var metrics: [Metric] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let strip = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: strip, xRadius: 7, yRadius: 7)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let items = style == .icon ? [] : Array(metrics.prefix(4))
        let pieces: [(width: CGFloat, draw: (NSPoint) -> Void)]
        switch style {
        case .icon: pieces = [iconPiece()]
        case .figure: pieces = items.map(figurePiece)
        case .graph: pieces = items.map(graphPiece)
        case .stacked: pieces = items.map(stackedPiece)
        }
        guard !pieces.isEmpty else { return }

        // Center the pieces like a group of menu bar extras.
        let spacing: CGFloat = 12
        let total = pieces.reduce(0) { $0 + $1.width } + spacing * CGFloat(pieces.count - 1)
        var x = (bounds.width - total) / 2
        for piece in pieces {
            piece.draw(NSPoint(x: x, y: bounds.midY))
            x += piece.width + spacing
        }
    }

    // MARK: Pieces (each draws around a vertical center line)

    private func iconPiece() -> (CGFloat, (NSPoint) -> Void) {
        let image = NSImage.symbol("gauge.with.dots.needle.33percent", size: 15, weight: .medium)
        return (image?.size.width ?? 18, { point in
            guard let image else { return }
            let size = image.size
            image.draw(in: NSRect(x: point.x, y: point.y - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        })
    }

    private func figurePiece(_ metric: Metric) -> (CGFloat, (NSPoint) -> Void) {
        let text = NSMutableAttributedString(string: Self.shortName(metric) + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        text.append(NSAttributedString(string: Self.sampleValue(metric), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]))
        let size = text.size()
        return (ceil(size.width), { point in text.draw(at: NSPoint(x: point.x, y: point.y - size.height / 2)) })
    }

    private func graphPiece(_ metric: Metric) -> (CGFloat, (NSPoint) -> Void) {
        let label = NSAttributedString(string: Self.shortName(metric), attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let labelSize = label.size()
        let graphWidth: CGFloat = 30
        let seed = Double(Preferences.menuBarChoices.firstIndex(of: metric) ?? 0)
        return (ceil(labelSize.width) + 3 + graphWidth, { point in
            label.draw(at: NSPoint(x: point.x, y: point.y - labelSize.height / 2))
            let box = NSRect(x: point.x + ceil(labelSize.width) + 3, y: point.y - 8, width: graphWidth, height: 16)
            // A deterministic wiggle stands in for recent samples.
            let bars = 10
            let barWidth = box.width / CGFloat(bars)
            Theme.color(for: metric).setFill()
            for index in 0..<bars {
                let value = 0.25 + 0.6 * abs(sin(Double(index) * 0.9 + seed * 1.7))
                let height = max(1.5, box.height * CGFloat(value))
                NSRect(x: box.minX + CGFloat(index) * barWidth, y: box.maxY - height, width: barWidth - 1, height: height).fill()
            }
        })
    }

    private func stackedPiece(_ metric: Metric) -> (CGFloat, (NSPoint) -> Void) {
        let top = NSAttributedString(string: Self.shortName(metric), attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let bottom = NSAttributedString(string: Self.sampleValue(metric), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        let width = ceil(max(top.size().width, bottom.size().width))
        return (width, { point in
            top.draw(at: NSPoint(x: point.x + (width - top.size().width) / 2, y: point.y - 11))
            bottom.draw(at: NSPoint(x: point.x + (width - bottom.size().width) / 2, y: point.y - 2))
        })
    }

    // MARK: Values

    private static func shortName(_ metric: Metric) -> String {
        switch metric {
        case .memory: return "MEM"
        case .network: return "NET"
        case .sensors: return "TEMP"
        case .battery: return "BAT"
        default: return metric.title.uppercased()
        }
    }

    /// Live values once the monitor has sampled, plausible placeholders before that.
    private static func sampleValue(_ metric: Metric) -> String {
        let monitor = Monitor.shared
        let live = monitor.hasSample ? monitor.snapshot : nil
        switch metric {
        case .cpu: return Format.percent(live?.cpu.total ?? 0.27)
        case .memory: return Format.percent(live?.memory.usedFraction ?? 0.61)
        case .gpu: return Format.percent(live?.gpu.utilization ?? 0.08)
        case .network: return Format.rate(live.map { $0.network.inRate + $0.network.outRate } ?? 184_000)
        case .disk: return Format.rate(live.map { $0.disk.readRate + $0.disk.writeRate } ?? 2_400_000)
        case .sensors: return Format.temperature(live?.sensors.cpuTemperature ?? 48)
        case .battery:
            if let live, live.battery.isPresent { return Format.percent(live.battery.charge) }
            return live == nil ? "86%" : "–"
        default: return ""
        }
    }
}

// MARK: - Alerts

private final class AlertsPane: SettingsPane {
    private var settings = AlertSettings.load()

    private var master: NSButton!
    private var cpuBox: NSButton!
    private var memoryBox: NSButton!
    private var diskBox: NSButton!
    private var networkBox: NSButton!
    private var pressureBox: NSButton!
    private var cpuThreshold: StepperField!
    private var cpuMinutes: StepperField!
    private var memoryGrowth: StepperField!
    private var diskRate: StepperField!
    private var networkRate: StepperField!
    private var testButton: NSButton!

    init() { super.init(title: "Alerts") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func buildForm() {
        master = checkbox("Notify me when an app misbehaves", action: #selector(controlChanged(_:)))
        addRow("Alerts:", master)

        cpuBox = checkbox("Above", action: #selector(controlChanged(_:)))
        cpuThreshold = StepperField(range: 10...800, step: 10, digits: 0, width: 46) { [weak self] _ in self?.save() }
        cpuMinutes = StepperField(range: 1...120, step: 1, digits: 0, width: 36) { [weak self] _ in self?.save() }
        addLine("High CPU:", [cpuBox, cpuThreshold, Self.text("% of a core for"), cpuMinutes, Self.text("min")], topPadding: 8)

        memoryBox = checkbox("Grows by", action: #selector(controlChanged(_:)))
        memoryGrowth = StepperField(range: 0.25...32, step: 0.25, digits: 2, width: 46) { [weak self] _ in self?.save() }
        addLine("Growing memory:", [memoryBox, memoryGrowth, Self.text("GB within an hour")])

        diskBox = checkbox("Writes over", action: #selector(controlChanged(_:)))
        diskRate = StepperField(range: 5...2000, step: 5, digits: 0, width: 46) { [weak self] _ in self?.save() }
        addLine("Heavy disk writes:", [diskBox, diskRate, Self.text("MB/s for 5 minutes")])

        networkBox = checkbox("Transfers over", action: #selector(controlChanged(_:)))
        networkRate = StepperField(range: 1...1000, step: 1, digits: 0, width: 46) { [weak self] _ in self?.save() }
        addLine("Heavy network:", [networkBox, networkRate, Self.text("MB/s for 5 minutes")])

        pressureBox = checkbox("Memory pressure stays critical for 2 minutes", action: #selector(controlChanged(_:)))
        addRow("System memory:", pressureBox)

        addNote("""
            Each app is watched on its own. CPU counts one fully busy core as 100%, so 200% means two. \
            After an alert, the same app stays quiet for an hour.
            """, indented: false, topPadding: 4)

        testButton = NSButton(title: "Send Test Notification", target: self, action: #selector(sendTest(_:)))
        addRow(nil, testButton, topPadding: 8)

        load()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        settings = AlertSettings.load()
        load()
    }

    private static func line(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    /// Rows with a number field center their label on the field instead of using baselines.
    private func addLine(_ label: String, _ views: [NSView], topPadding: CGFloat = 0) {
        let row = addRow(label, Self.line(views), topPadding: topPadding)
        row.rowAlignment = .none
        row.yPlacement = .center
    }

    private static func text(_ string: String) -> NSTextField {
        NSTextField(labelWithString: string)
    }

    private func load() {
        master.state = settings.enabled ? .on : .off
        cpuBox.state = settings.cpu ? .on : .off
        memoryBox.state = settings.memory ? .on : .off
        diskBox.state = settings.disk ? .on : .off
        networkBox.state = settings.network ? .on : .off
        pressureBox.state = settings.systemMemory ? .on : .off
        cpuThreshold.value = settings.cpuThreshold
        cpuMinutes.value = Double(settings.cpuMinutes)
        memoryGrowth.value = settings.memoryGrowthGB
        diskRate.value = settings.diskMBps
        networkRate.value = settings.networkMBps
        updateEnabled()
    }

    private func updateEnabled() {
        let on = master.state == .on
        for box in [cpuBox, memoryBox, diskBox, networkBox, pressureBox] { box?.isEnabled = on }
        cpuThreshold.isEnabled = on && cpuBox.state == .on
        cpuMinutes.isEnabled = on && cpuBox.state == .on
        memoryGrowth.isEnabled = on && memoryBox.state == .on
        diskRate.isEnabled = on && diskBox.state == .on
        networkRate.isEnabled = on && networkBox.state == .on
    }

    @objc private func controlChanged(_ sender: Any?) {
        save()
    }

    private func save() {
        settings.enabled = master.state == .on
        settings.cpu = cpuBox.state == .on
        settings.cpuThreshold = cpuThreshold.value
        settings.cpuMinutes = Int(cpuMinutes.value.rounded())
        settings.memory = memoryBox.state == .on
        settings.memoryGrowthGB = memoryGrowth.value
        settings.disk = diskBox.state == .on
        settings.diskMBps = diskRate.value
        settings.network = networkBox.state == .on
        settings.networkMBps = networkRate.value
        settings.systemMemory = pressureBox.state == .on
        settings.save()
        updateEnabled()
    }

    // MARK: Test notification

    @objc private func sendTest(_ sender: Any?) {
        // UNUserNotificationCenter only works from inside an app bundle.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            NSSound.beep()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { notificationSettings in
            switch notificationSettings.authorizationStatus {
            case .denied:
                DispatchQueue.main.async { [weak self] in self?.explainNotificationsOff() }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Self.postTestNotification()
                    } else {
                        DispatchQueue.main.async { [weak self] in self?.explainNotificationsOff() }
                    }
                }
            default:
                Self.postTestNotification()
            }
        }
    }

    private static func postTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Test alert from OpenActivity"
        content.body = "Alerts are working. A real one names the app and what it is doing."
        content.sound = .default
        content.userInfo = ["metric": Metric.overview.rawValue]
        let request = UNNotificationRequest(identifier: "openactivity.test", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Settings: cannot post test notification: %@", error.localizedDescription) }
        }
    }

    private func explainNotificationsOff() {
        let alert = NSAlert()
        alert.messageText = "Notifications are off for OpenActivity"
        alert.informativeText = "To receive alerts, allow notifications for OpenActivity in System Settings › Notifications."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let open = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { open() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            open()
        }
    }
}

/// A number field with a stepper beside it. Reports changes from either control.
private final class StepperField: NSStackView {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let formatter = NumberFormatter()
    private let onChange: (Double) -> Void

    var value: Double {
        get { stepper.doubleValue }
        set {
            stepper.doubleValue = min(stepper.maxValue, max(stepper.minValue, newValue))
            field.doubleValue = stepper.doubleValue
        }
    }

    var isEnabled: Bool = true {
        didSet {
            field.isEnabled = isEnabled
            stepper.isEnabled = isEnabled
        }
    }

    init(range: ClosedRange<Double>, step: Double, digits: Int, width: CGFloat, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 2

        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.isLenient = true

        field.formatter = formatter
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.target = self
        field.action = #selector(fieldChanged(_:))
        // Commit on Tab, click-away and window close too, not only on Return.
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: width).isActive = true

        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))

        addArrangedSubview(field)
        addArrangedSubview(stepper)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func stepperChanged(_ sender: NSStepper) {
        field.doubleValue = sender.doubleValue
        onChange(sender.doubleValue)
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        value = sender.doubleValue
        onChange(value)
    }
}

// MARK: - History

private final class HistoryPane: SettingsPane {
    private let summary = NSTextField(labelWithString: "")
    private var clearButton: NSButton!

    init() { super.init(title: "History") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func buildForm() {
        summary.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        addRow("Stored:", summary)
        addNote("""
            OpenActivity keeps a minute-by-minute record for the charts and per-app totals. \
            Anything older than \(Self.retentionDays) days is removed automatically.
            """, indented: false, topPadding: -4)

        clearButton = NSButton(title: "Clear History…", target: self, action: #selector(confirmClear(_:)))
        addRow(nil, clearButton, topPadding: 4)

        let privacy = Self.note("""
            History is saved in a small database in your Library folder. It stays on this Mac \
            and is never uploaded, synced or shared.
            """, width: Self.controlColumnWidth)
        privacy.font = .systemFont(ofSize: NSFont.systemFontSize)
        addRow("Privacy:", privacy, topPadding: 14)

        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealDatabase(_:)))
        addRow(nil, reveal)
    }

    private static var retentionDays: Int { Int(HistoryStore.retention / 86_400) }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        let size = HistoryStore.shared.fileSize
        summary.stringValue = size == 0
            ? "Nothing yet"
            : "Up to \(Self.retentionDays) days · \(Format.bytes(size))"
    }

    @objc private func confirmClear(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all history?"
        alert.informativeText = "Charts and per-app totals for the past \(Self.retentionDays) days will be deleted. Live figures are not affected. This can’t be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.clear()
        }
    }

    private func clear() {
        clearButton.isEnabled = false
        summary.stringValue = "Clearing…"
        // Clearing vacuums the database, which can take a moment.
        DispatchQueue.global(qos: .userInitiated).async {
            HistoryStore.shared.clear()
            DispatchQueue.main.async { [weak self] in
                self?.clearButton.isEnabled = true
                self?.refresh()
            }
        }
    }

    @objc private func revealDatabase(_ sender: Any?) {
        let url = HistoryStore.shared.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

// MARK: - About

private final class AboutPane: SettingsPane {
    init() { super.init(title: "About") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func buildForm() {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "OpenActivity"
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let versionText = build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
        let versionLabel = NSTextField(labelWithString: versionText)
        versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.isSelectable = true

        let tagline = NSTextField(labelWithString: "See which apps use your Mac, and how much.")
        tagline.textColor = .secondaryLabelColor

        let privacy = Self.note("""
            OpenActivity has no accounts and no analytics. It reads figures from macOS on this Mac, \
            keeps its history in a local file, and sends nothing anywhere. Alerts are ordinary \
            notifications posted by the app itself.
            """, width: 400)
        privacy.alignment = .center

        let stack = NSStackView(views: [icon, title, versionLabel, tagline, privacy])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(14, after: tagline)

        // One full-width cell so the column stays centered in the window.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.margin).isActive = true
        let row = grid.addRow(with: [stack])
        row.rowAlignment = .none
        row.bottomPadding = 4
    }
}
