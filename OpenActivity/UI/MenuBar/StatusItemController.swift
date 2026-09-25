//
//  StatusItemController.swift
//  OpenActivity
//
//  The menu bar item. Draws the chosen figures or graphs into one image, redrawn only when what
//  it shows changes. Left click toggles the popover dashboard, right click opens a short menu.
//

import AppKit

final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let popoverController = PopoverViewController()
    private var monitorToken: Monitor.Token?
    private var preferencesObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var drawnCells: [MenuBarCell]?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = popoverController
        popover.delegate = self
        popoverController.dismiss = { [weak self] in self?.closePopover() }

        statusItem.autosaveName = "OpenActivityStatusItem"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityTitle("OpenActivity")
        }

        redraw(Monitor.shared.snapshot)
        monitorToken = Monitor.shared.observe { [weak self] snapshot in self?.redraw(snapshot) }
        preferencesObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.redraw(Monitor.shared.snapshot)
        }
        #if DEBUG
        // `-debug.showPopover YES` opens the dashboard at launch, for screenshots and UI checks.
        if UserDefaults.standard.bool(forKey: "debug.showPopover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showPopover()
            }
        }
        #endif
    }

    deinit {
        if let monitorToken { Monitor.shared.removeObserver(monitorToken) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Drawing

    private func redraw(_ snapshot: SystemSnapshot) {
        let preferences = Preferences.shared
        let cells = MenuBarCell.cells(
            style: preferences.menuBarStyle,
            metrics: preferences.menuBarMetrics,
            snapshot: snapshot,
            recent: Monitor.shared.recent,
            hasSample: Monitor.shared.hasSample
        )
        guard cells != drawnCells, let button = statusItem.button else { return }
        drawnCells = cells
        button.image = MenuBarRenderer.image(for: cells)
        button.toolTip = Monitor.shared.hasSample ? MenuBarCell.toolTip(for: snapshot) : "OpenActivity"
    }

    // MARK: - Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // A transient popover only notices clicks inside this app; close it on clicks anywhere else too.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func showMenu() {
        closePopover()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open OpenActivity", action: #selector(openMainWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OpenActivity", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Attaching the menu for a single click gives the native highlight and placement.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openMainWindow() {
        AppDelegate.shared.showMainWindow(page: nil)
    }

    @objc private func openSettings() {
        AppDelegate.shared.showSettings(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        Monitor.shared.setInteractive(true, reason: "popover")
    }

    func popoverDidShow(_ notification: Notification) {
        statusItem.button?.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        Monitor.shared.setInteractive(false, reason: "popover")
        statusItem.button?.highlight(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}

// MARK: - What the menu bar shows

/// One block of the menu bar image. Equatable so the image is only redrawn when a block changes.
private enum MenuBarCell: Equatable {
    enum Tint: Equatable { case normal, warning, critical }

    /// A single SF Symbol, orange when the Mac is under strain.
    case symbol(name: String, warning: Bool)
    /// A tiny caption beside a figure. `sample` reserves the width.
    case figure(caption: String, value: String, sample: String, tint: Tint)
    /// Two short centered lines, usually a caption above a figure.
    case lines(top: String, bottom: String, topSample: String, bottomSample: String, captionOnTop: Bool, tint: Tint)
    /// Download above and upload below, each with an arrow.
    case rates(down: String, up: String)
    /// A tiny caption beside a 32×16 graph. Values are quantized heights (0...graphSteps).
    case graph(caption: String, values: [Int], mirrored: [Int]?, tint: Tint)

    var isTinted: Bool {
        switch self {
        case .symbol(_, let warning): return warning
        case .figure(_, _, _, let tint), .lines(_, _, _, _, _, let tint), .graph(_, _, _, let tint): return tint != .normal
        case .rates: return false
        }
    }

    static let graphSamples = 32
    static let graphSteps = 28
    static let normalSymbol = "gauge.with.dots.needle.33percent"
    static let warningSymbol = "exclamationmark.triangle.fill"

    static func cells(style: MenuBarStyle, metrics: [Metric], snapshot: SystemSnapshot, recent: RecentHistory, hasSample: Bool) -> [MenuBarCell] {
        let strain = Strain(snapshot: snapshot, recent: recent, hasSample: hasSample)
        guard style != .icon, !metrics.isEmpty else {
            return [.symbol(name: strain.any ? warningSymbol : normalSymbol, warning: strain.any)]
        }
        return metrics.map { metric in
            switch style {
            case .graph: return graphCell(metric, snapshot: snapshot, recent: recent, strain: strain)
            case .stacked:
                if metric == .network { return rateCell(snapshot, hasSample: hasSample) }
                let figure = self.figure(metric, snapshot: snapshot, hasSample: hasSample)
                return .lines(top: figure.caption, bottom: figure.value, topSample: figure.caption, bottomSample: figure.sample,
                              captionOnTop: true, tint: strain.tint(for: metric))
            case .figure, .icon:
                if metric == .network { return rateCell(snapshot, hasSample: hasSample) }
                let figure = self.figure(metric, snapshot: snapshot, hasSample: hasSample)
                return .figure(caption: figure.caption, value: figure.value, sample: figure.sample, tint: strain.tint(for: metric))
            }
        }
    }

    private static func rateCell(_ snapshot: SystemSnapshot, hasSample: Bool) -> MenuBarCell {
        guard hasSample else { return .rates(down: "–", up: "–") }
        return .rates(down: compactRate(snapshot.network.inRate), up: compactRate(snapshot.network.outRate))
    }

    /// "737 kB" instead of "737 kB/s"; the arrows already say it's a rate.
    static func compactRate(_ bytesPerSecond: Double) -> String {
        Format.rate(bytesPerSecond).replacingOccurrences(of: "/s", with: "")
    }

    private static func figure(_ metric: Metric, snapshot: SystemSnapshot, hasSample: Bool) -> (caption: String, value: String, sample: String) {
        let dash = "–"
        switch metric {
        case .cpu:
            return ("CPU", hasSample ? Format.percent(snapshot.cpu.total) : dash, "100%")
        case .memory:
            return ("MEM", hasSample ? Format.percent(snapshot.memory.usedFraction) : dash, "100%")
        case .gpu:
            return ("GPU", hasSample ? Format.percent(snapshot.gpu.utilization) : dash, "100%")
        case .disk:
            let root = snapshot.disk.rootVolume
            let used = root.map { $0.total == 0 ? 0 : Double($0.used) / Double($0.total) }
            return ("DISK", hasSample ? used.map(Format.percent) ?? dash : dash, "100%")
        case .sensors:
            return ("TMP", hasSample ? Format.temperature(snapshot.sensors.cpuTemperature) : dash, "100°")
        case .battery:
            if hasSample && !snapshot.battery.isPresent {
                return ("PWR", Format.watts(snapshot.battery.systemPower), "88.8 W")
            }
            return ("BAT", hasSample ? Format.percent(snapshot.battery.charge) : dash, "100%")
        default:
            return (metric.title.uppercased(), dash, "100%")
        }
    }

    private static func graphCell(_ metric: Metric, snapshot: SystemSnapshot, recent: RecentHistory, strain: Strain) -> MenuBarCell {
        let tint = strain.tint(for: metric)
        switch metric {
        case .cpu: return .graph(caption: "CPU", values: quantize(recent.cpu.values, top: 1), mirrored: nil, tint: tint)
        case .memory: return .graph(caption: "MEM", values: quantize(recent.memory.values, top: 1), mirrored: nil, tint: tint)
        case .gpu: return .graph(caption: "GPU", values: quantize(recent.gpu.values, top: 1), mirrored: nil, tint: tint)
        case .disk:
            let total = zip(recent.diskRead.values, recent.diskWrite.values).map { $0 + $1 }
            let top = max(total.suffix(graphSamples).max() ?? 0, 1_000_000)
            return .graph(caption: "DISK", values: quantize(total, top: top), mirrored: nil, tint: tint)
        case .network:
            let incoming = recent.netIn.values.suffix(graphSamples), outgoing = recent.netOut.values.suffix(graphSamples)
            let top = max(incoming.max() ?? 0, outgoing.max() ?? 0, 100_000)
            return .graph(caption: "NET", values: quantize(Array(incoming), top: top, steps: graphSteps / 2),
                          mirrored: quantize(Array(outgoing), top: top, steps: graphSteps / 2), tint: tint)
        case .sensors:
            // 30 °C at the bottom, 100 °C at the top.
            let scaled = recent.temperature.values.map { $0 <= 0 ? 0 : ($0 - 30) / 70 }
            return .graph(caption: "TMP", values: quantize(scaled, top: 1), mirrored: nil, tint: tint)
        case .battery:
            if snapshot.battery.isPresent {
                return .graph(caption: "BAT", values: quantize(recent.battery.values, top: 1), mirrored: nil, tint: tint)
            }
            let top = max(recent.power.values.suffix(graphSamples).max() ?? 0, 10)
            return .graph(caption: "PWR", values: quantize(recent.power.values, top: top), mirrored: nil, tint: tint)
        default:
            return .graph(caption: metric.title.uppercased(), values: [], mirrored: nil, tint: tint)
        }
    }

    private static func quantize(_ values: [Double], top: Double, steps: Int = graphSteps) -> [Int] {
        values.suffix(graphSamples).map { value in
            guard value.isFinite, top > 0 else { return 0 }
            return Int((min(1, max(0, value / top)) * Double(steps)).rounded())
        }
    }

    static func toolTip(for snapshot: SystemSnapshot) -> String {
        var parts = [
            "CPU \(Format.percent(snapshot.cpu.total))",
            "Memory \(Format.memory(snapshot.memory.used)) of \(Format.memory(snapshot.memory.total))",
            "↓ \(Format.rate(snapshot.network.inRate))  ↑ \(Format.rate(snapshot.network.outRate))",
        ]
        if snapshot.memory.pressure != .normal { parts.append("Memory pressure: \(snapshot.memory.pressure.title)") }
        return parts.joined(separator: "\n")
    }
}

/// Signs that the Mac is struggling.
private struct Strain {
    var cpu = false
    var memory: MemoryPressure = .normal
    var hot = false

    init(snapshot: SystemSnapshot, recent: RecentHistory, hasSample: Bool) {
        guard hasSample else { return }
        let lastFive = recent.cpu.values.suffix(5)
        cpu = lastFive.count == 5 && lastFive.allSatisfy { $0 > 0.9 }
        memory = snapshot.memory.pressure
        hot = (snapshot.sensors.cpuTemperature ?? 0) >= 95
    }

    var any: Bool { cpu || memory != .normal || hot }

    func tint(for metric: Metric) -> MenuBarCell.Tint {
        switch metric {
        case .cpu: return cpu ? .warning : .normal
        case .memory: return memory == .critical ? .critical : memory == .warning ? .warning : .normal
        case .sensors: return hot ? .warning : .normal
        default: return .normal
        }
    }
}

// MARK: - Rendering

/// Draws cells into one image. Without tinted cells the image is a template, so the menu bar tints
/// it for light, dark and highlighted states. With a tint it draws with dynamic label colors, which
/// resolve against the button's appearance at draw time.
private enum MenuBarRenderer {
    static let height: CGFloat = 22
    static let cellSpacing: CGFloat = 7

    static let captionFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
    static let figureFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    static let lineCaptionFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    static let graphCaptionFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    static let graphSize = NSSize(width: 32, height: 16)

    struct Palette {
        var primary: NSColor
        var secondary: NSColor
        var faint: NSColor

        func tinted(_ tint: MenuBarCell.Tint) -> NSColor {
            switch tint {
            case .normal: return primary
            case .warning: return .systemOrange
            case .critical: return .systemRed
            }
        }
    }

    static func image(for cells: [MenuBarCell]) -> NSImage {
        let template = !cells.contains(where: \.isTinted)
        let palette = template
            ? Palette(primary: .black, secondary: NSColor.black.withAlphaComponent(0.6), faint: NSColor.black.withAlphaComponent(0.3))
            : Palette(primary: .labelColor, secondary: .secondaryLabelColor, faint: .tertiaryLabelColor)
        let widths = cells.map(width)
        let total = widths.reduce(0, +) + cellSpacing * CGFloat(max(0, cells.count - 1))
        let size = NSSize(width: ceil(total), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (cell, width) in zip(cells, widths) {
                draw(cell, in: NSRect(x: x, y: 0, width: width, height: height), palette: palette)
                x += width + cellSpacing
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "OpenActivity"
        return image
    }

    // MARK: Measuring

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static let captionGap: CGFloat = 3
    private static let arrowGap: CGFloat = 2

    private static func width(of cell: MenuBarCell) -> CGFloat {
        switch cell {
        case .symbol:
            return 18
        case let .figure(caption, value, sample, _):
            return textWidth(caption, captionFont) + captionGap + max(textWidth(sample, figureFont), textWidth(value, figureFont))
        case let .lines(top, bottom, topSample, bottomSample, captionOnTop, _):
            let topFont = captionOnTop ? lineCaptionFont : lineFont
            return max(textWidth(topSample, topFont), textWidth(top, topFont), textWidth(bottomSample, lineFont), textWidth(bottom, lineFont))
        case let .rates(down, up):
            let figure = max(textWidth(rateSample, lineFont), textWidth(down, lineFont), textWidth(up, lineFont))
            return textWidth("↓", lineFont) + arrowGap + figure
        case let .graph(caption, _, _, _):
            return max(textWidth(caption, graphCaptionFont), 16) + captionGap + graphSize.width
        }
    }

    private static let rateSample = "888 kB"

    // MARK: Drawing

    /// Draws text with its baseline at `baseline`, left, right or center aligned in `rect`.
    private static func drawText(_ text: String, font: NSFont, color: NSColor, baseline: CGFloat, in rect: NSRect, alignment: NSTextAlignment) {
        let string = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = string.size(withAttributes: attributes).width
        let x: CGFloat
        switch alignment {
        case .right: x = rect.maxX - width
        case .center: x = rect.midX - width / 2
        default: x = rect.minX
        }
        string.draw(at: NSPoint(x: x, y: baseline + font.descender), withAttributes: attributes)
    }

    /// Baselines for two lines of `font`, centered as a block in the bar.
    private static func twoLineBaselines(_ font: NSFont) -> (top: CGFloat, bottom: CGFloat) {
        let step = (font.capHeight + 3.8).rounded()
        let bottom = ((height - font.capHeight - step) / 2).rounded()
        return (bottom + step, bottom)
    }

    private static func draw(_ cell: MenuBarCell, in rect: NSRect, palette: Palette) {
        switch cell {
        case let .symbol(name, warning):
            let color: NSColor = warning ? .systemOrange : palette.primary
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(.init(paletteColors: [color]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            let size = symbol.size
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            symbol.draw(in: NSRect(origin: origin, size: size).integral)

        case let .figure(caption, value, _, tint):
            let baseline = ((height - figureFont.capHeight) / 2).rounded()
            let captionWidth = textWidth(caption, captionFont)
            drawText(caption, font: captionFont, color: tint == .normal ? palette.secondary : palette.tinted(tint),
                     baseline: baseline, in: rect, alignment: .left)
            var valueRect = rect
            valueRect.origin.x += captionWidth + captionGap
            valueRect.size.width -= captionWidth + captionGap
            drawText(value, font: figureFont, color: palette.tinted(tint), baseline: baseline, in: valueRect, alignment: .right)

        case let .lines(top, bottom, _, _, captionOnTop, tint):
            let baselines = twoLineBaselines(lineFont)
            drawText(top, font: captionOnTop ? lineCaptionFont : lineFont,
                     color: captionOnTop && tint == .normal ? palette.secondary : palette.tinted(tint),
                     baseline: baselines.top, in: rect, alignment: .center)
            drawText(bottom, font: lineFont, color: palette.tinted(tint), baseline: baselines.bottom, in: rect, alignment: .center)

        case let .rates(down, up):
            let baselines = twoLineBaselines(lineFont)
            drawText("↓", font: lineFont, color: palette.secondary, baseline: baselines.top, in: rect, alignment: .left)
            drawText("↑", font: lineFont, color: palette.secondary, baseline: baselines.bottom, in: rect, alignment: .left)
            drawText(down, font: lineFont, color: palette.primary, baseline: baselines.top, in: rect, alignment: .right)
            drawText(up, font: lineFont, color: palette.primary, baseline: baselines.bottom, in: rect, alignment: .right)

        case let .graph(caption, values, mirrored, tint):
            let captionWidth = max(textWidth(caption, graphCaptionFont), 16)
            let baseline = ((height - graphCaptionFont.capHeight) / 2).rounded()
            drawText(caption, font: graphCaptionFont, color: tint == .normal ? palette.secondary : palette.tinted(tint),
                     baseline: baseline, in: NSRect(x: rect.minX, y: 0, width: captionWidth, height: height), alignment: .left)
            let box = NSRect(x: rect.maxX - graphSize.width, y: ((height - graphSize.height) / 2).rounded(),
                             width: graphSize.width, height: graphSize.height)
            drawGraph(values: values, mirrored: mirrored, in: box, color: palette.tinted(tint), frame: palette.faint)
        }
    }

    private static func drawGraph(values: [Int], mirrored: [Int]?, in box: NSRect, color: NSColor, frame: NSColor) {
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        frame.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        let plot = box.insetBy(dx: 1.5, dy: 1.5)
        let steps = CGFloat(MenuBarCell.graphSteps)
        if let mirrored {
            let half = plot.height / 2
            fillArea(values, baseline: plot.midY, scale: half / (steps / 2), direction: 1, in: plot, color: color)
            fillArea(mirrored, baseline: plot.midY, scale: half / (steps / 2), direction: -1, in: plot, color: color.withAlphaComponent(0.6))
        } else {
            fillArea(values, baseline: plot.minY, scale: plot.height / steps, direction: 1, in: plot, color: color)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Bars, one point per sample, growing in from the right edge.
    private static func fillArea(_ values: [Int], baseline: CGFloat, scale: CGFloat, direction: CGFloat, in plot: NSRect, color: NSColor) {
        guard !values.isEmpty else { return }
        let step = plot.width / CGFloat(MenuBarCell.graphSamples)
        let start = plot.maxX - step * CGFloat(values.count)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: start, y: baseline))
        for (index, value) in values.enumerated() {
            let y = baseline + direction * CGFloat(value) * scale
            path.line(to: NSPoint(x: start + step * CGFloat(index), y: y))
            path.line(to: NSPoint(x: start + step * CGFloat(index + 1), y: y))
        }
        path.line(to: NSPoint(x: plot.maxX, y: baseline))
        path.close()
        color.setFill()
        path.fill()
    }
}
