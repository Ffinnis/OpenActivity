//
//  SensorsViewController.swift
//  OpenActivity
//
//  Temperatures, fan speeds and the batteries of connected accessories.
//

import AppKit

final class SensorsViewController: NSViewController, LivePage {
    private let cpuFigure = BigFigureView()
    private let gpuFigure = BigFigureView()
    private let fanFigure = BigFigureView()
    private let fanCaption = NSTextField.caption()
    private let chart = ChartView(style: .full, height: 150)
    private let temperatureList = NSStackView.vertical(spacing: 8)
    private let fanList = NSStackView.vertical(spacing: 10)
    private let accessoryList = NSStackView.vertical(spacing: 10)
    private let fansCard = CardView(frame: .zero)
    private var temperatureRows: [String: (label: NSTextField, meter: MeterView)] = [:]
    private var fanRows: [String: (label: NSTextField, meter: MeterView)] = [:]
    private var accessoryRows: [String: (label: NSTextField, ring: RingView)] = [:]

    override func loadView() {
        let page = NSStackView.vertical(spacing: Theme.cardSpacing, alignment: .leading)

        let headline = GridStack(columns: 3)
        headline.setItems([
            CardView([CardHeader(title: "CPU", symbol: "cpu", color: Theme.color(for: .cpu)), cpuFigure, NSTextField.caption("Average of the CPU sensors")]),
            CardView([CardHeader(title: "GPU", symbol: "cube.transparent", color: Theme.color(for: .gpu)), gpuFigure, NSTextField.caption("Average of the GPU sensors")]),
            CardView([CardHeader(title: "Fans", symbol: "fanblades", color: .systemTeal), fanFigure, fanCaption]),
        ])
        page.addArrangedSubview(headline)

        chart.valueFormatter = { "\(Int($0.rounded()))°" }
        chart.maxValue = 100
        let chartCard = CardView([CardHeader(title: "CPU temperature", symbol: "waveform.path.ecg", color: Theme.color(for: .sensors)), chart])
        chart.widthAnchor.constraint(equalTo: chartCard.content.widthAnchor).isActive = true
        page.addArrangedSubview(chartCard)

        let temperatures = CardView([CardHeader(title: "Temperatures", symbol: "thermometer.medium", color: Theme.color(for: .sensors)), temperatureList])
        temperatureList.widthAnchor.constraint(equalTo: temperatures.content.widthAnchor).isActive = true

        fansCard.content.addArrangedSubview(CardHeader(title: "Fan speeds", symbol: "fanblades.fill", color: .systemTeal))
        fansCard.content.addArrangedSubview(fanList)
        fanList.widthAnchor.constraint(equalTo: fansCard.content.widthAnchor).isActive = true

        let accessories = CardView([CardHeader(title: "Accessory batteries", symbol: "airpodspro", color: Theme.color(for: .battery)), accessoryList])
        accessoryList.widthAnchor.constraint(equalTo: accessories.content.widthAnchor).isActive = true

        let details = GridStack(columns: 3)
        details.setItems([temperatures, fansCard, accessories])
        page.addArrangedSubview(details)

        for view in [headline, chartCard, details] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
        view = NSScrollView.page(with: page)
    }

    func update(with snapshot: SystemSnapshot) {
        let sensors = snapshot.sensors
        cpuFigure.update(Format.temperature(sensors.cpuTemperature).replacingOccurrences(of: "°", with: ""), unit: "°C")
        gpuFigure.update(Format.temperature(sensors.gpuTemperature).replacingOccurrences(of: "°", with: ""), unit: "°C")
        if sensors.fans.isEmpty {
            fanFigure.update("–")
            fanCaption.set("This Mac has no fans to report")
        } else {
            let average = sensors.fans.reduce(0) { $0 + $1.rpm } / Double(sensors.fans.count)
            fanFigure.update(Format.rpm(average), unit: "rpm")
            fanCaption.set(sensors.fans.count == 1 ? "1 fan" : "Average of \(sensors.fans.count) fans")
        }
        chart.series = [.init(values: Monitor.shared.recent.temperature.values, color: Theme.color(for: .sensors))]

        syncRows(sensors.temperatures.map(\.name), list: temperatureList, rows: &temperatureRows, empty: "No temperature sensors available") { name in
            let label = NSTextField.number("", size: 12, weight: .medium)
            let meter = MeterView(height: 5)
            return (label, meter)
        }
        for reading in sensors.temperatures {
            guard let row = temperatureRows[reading.name] else { continue }
            row.label.set(Format.temperature(reading.celsius))
            row.meter.value = reading.celsius / 110
            row.meter.color = Theme.temperatureColor(reading.celsius)
        }

        syncRows(sensors.fans.map(\.name), list: fanList, rows: &fanRows, empty: "No fans reported") { _ in
            (NSTextField.number("", size: 12, weight: .medium), MeterView(height: 5))
        }
        for fan in sensors.fans {
            guard let row = fanRows[fan.name] else { continue }
            row.label.set("\(Format.rpm(fan.rpm)) rpm")
            let span = max(1, fan.maxRPM - fan.minRPM)
            row.meter.value = fan.maxRPM > 0 ? max(0, fan.rpm - fan.minRPM) / span : 0
            row.meter.color = .systemTeal
        }

        updateAccessories(snapshot.peripherals)
    }

    /// Adds and removes rows so the lists match the sensors without rebuilding on every sample.
    private func syncRows(_ names: [String], list: NSStackView, rows: inout [String: (label: NSTextField, meter: MeterView)],
                          empty: String, make: (String) -> (NSTextField, MeterView)) {
        guard Set(names) != Set(rows.keys) || list.arrangedSubviews.isEmpty else { return }
        list.removeAllArrangedSubviews()
        rows.removeAll()
        if names.isEmpty {
            list.addArrangedSubview(NSTextField.label(empty, size: 12, color: .tertiaryLabelColor))
            return
        }
        for name in names {
            let (label, meter) = make(name)
            label.alignment = .right
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            let title = NSTextField.label(name, size: 12, color: .secondaryLabelColor)
            let row = NSStackView.vertical([NSStackView.horizontal([title, NSView.spacer(), label]), meter], spacing: 4)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            row.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
            rows[name] = (label, meter)
        }
    }

    private func updateAccessories(_ peripherals: [PeripheralBattery]) {
        let names = peripherals.map(\.name)
        if Set(names) != Set(accessoryRows.keys) || accessoryList.arrangedSubviews.isEmpty {
            accessoryList.removeAllArrangedSubviews()
            accessoryRows.removeAll()
            if peripherals.isEmpty {
                accessoryList.addArrangedSubview(NSTextField.wrapping("Connect AirPods, a Magic Mouse, keyboard or trackpad to see its battery here.", size: 12, color: .tertiaryLabelColor))
            }
            for peripheral in peripherals {
                let ring = RingView(diameter: 34)
                ring.lineWidth = 4
                ring.label.font = Theme.numberFont(9, weight: .semibold)
                let icon = NSImageView(image: NSImage.symbol(Self.symbol(for: peripheral.kind), size: 14, color: .secondaryLabelColor) ?? NSImage())
                let name = NSTextField.label(peripheral.name, size: 12, weight: .medium)
                let state = NSTextField.caption()
                let row = NSStackView.horizontal([icon, NSStackView.vertical([name, state], spacing: 1), NSView.spacer(), ring], spacing: 8)
                accessoryList.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: accessoryList.widthAnchor).isActive = true
                accessoryRows[peripheral.name] = (state, ring)
            }
        }
        for peripheral in peripherals {
            guard let row = accessoryRows[peripheral.name] else { continue }
            row.ring.value = peripheral.charge
            row.ring.label.set(Format.percent(peripheral.charge))
            row.ring.color = peripheral.charge < 0.2 ? .systemRed : Theme.color(for: .battery)
            row.label.set(peripheral.isCharging ? "Charging" : peripheral.kind)
        }
    }

    private static func symbol(for kind: String) -> String {
        switch kind {
        case "AirPods": return "airpodspro"
        case "Headphones": return "headphones"
        case "Mouse": return "magicmouse"
        case "Keyboard": return "keyboard"
        case "Trackpad": return "rectangle.and.hand.point.up.left"
        default: return "battery.75percent"
        }
    }
}
