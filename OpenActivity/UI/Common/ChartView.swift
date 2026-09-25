//
//  ChartView.swift
//  OpenActivity
//
//  Area charts: small sparklines on cards and a full chart with axis and hover readout.
//

import AppKit

final class ChartView: NSView {
    struct Series {
        var values: [Double]
        var color: NSColor
        var name: String = ""
        /// Draw below the baseline (upload under download).
        var mirrored = false
    }

    struct TimedSeries {
        var points: [(date: Date, value: Double)]
        var color: NSColor
        var name: String = ""
    }

    enum Style { case sparkline, full }

    var style: Style = .sparkline { didSet { needsDisplay = true } }
    var series: [Series] = [] { didSet { timedSeries = []; needsDisplay = true } }
    var timedSeries: [TimedSeries] = [] { didSet { needsDisplay = true } }
    /// Upper bound of the y axis. nil scales to the data.
    var maxValue: Double?
    /// Number of samples the sparkline spans, so a fresh chart grows from the right.
    var capacity = 150
    var valueFormatter: (Double) -> String = { Format.percent($0) }
    var timeRange: ClosedRange<Date>?
    var emptyText = "Collecting history…"

    private var hoverX: CGFloat?

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()

    private static let hoverTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static let hoverDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Until the buffer fills, the chart spans at least a minute of samples rather than squeezing
    /// a few points into the right edge.
    private var visibleSpan: Int {
        let longest = series.map(\.values.count).max() ?? 0
        return max(2, min(capacity, max(longest, 30)))
    }
    private var trackingArea: NSTrackingArea?

    init(style: Style = .sparkline, height: CGFloat? = nil) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let height { heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard style == .full else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }

    private var plotRect: NSRect {
        switch style {
        case .sparkline: return bounds.insetBy(dx: 0, dy: 1)
        case .full: return NSRect(x: 0, y: 18, width: bounds.width - 52, height: bounds.height - 26)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect
        guard plot.width > 4, plot.height > 4 else { return }

        let mirrored = series.contains(where: \.mirrored)
        let allValues = timedSeries.isEmpty ? series.flatMap(\.values) : timedSeries.flatMap { $0.points.map(\.value) }
        let top = niceCeiling(maxValue ?? max(allValues.max() ?? 0, 0.000_001))

        if style == .full { drawGrid(in: plot, top: top, mirrored: mirrored && timedSeries.isEmpty) }

        let hasData = timedSeries.isEmpty ? series.contains { $0.values.count > 1 } : timedSeries.contains { !$0.points.isEmpty }
        guard hasData else {
            if style == .full { drawEmpty(in: plot) }
            return
        }

        if timedSeries.isEmpty {
            let baseline = mirrored ? plot.midY : plot.minY
            let half = mirrored ? plot.height / 2 : plot.height
            let span = visibleSpan
            for item in series {
                let points = item.values.suffix(span).enumerated().map { offset, value -> NSPoint in
                    let index = span - min(span, item.values.count) + offset
                    let x = plot.minX + plot.width * CGFloat(index) / CGFloat(max(1, span - 1))
                    let height = half * CGFloat(min(1, value / top))
                    return NSPoint(x: x, y: item.mirrored ? baseline - height : baseline + height)
                }
                drawArea(points, baseline: baseline, color: item.color, in: plot)
            }
            if mirrored {
                NSColor.separatorColor.setFill()
                NSRect(x: plot.minX, y: plot.midY - 0.25, width: plot.width, height: 0.5).fill()
            }
        } else {
            let range = timeRange ?? {
                let dates = timedSeries.flatMap { $0.points.map(\.date) }
                return (dates.min() ?? Date())...(dates.max() ?? Date())
            }()
            let span = max(1, range.upperBound.timeIntervalSince(range.lowerBound))
            for item in timedSeries {
                // Split at gaps (sleep, app not running) so the chart never invents data.
                let gap = span / 60
                var segments: [[NSPoint]] = [[]]
                var previous: Date?
                for point in item.points {
                    if let previous, point.date.timeIntervalSince(previous) > gap * 3 { segments.append([]) }
                    let x = plot.minX + plot.width * CGFloat(point.date.timeIntervalSince(range.lowerBound) / span)
                    let y = plot.minY + plot.height * CGFloat(min(1, point.value / top))
                    segments[segments.count - 1].append(NSPoint(x: x, y: y))
                    previous = point.date
                }
                for segment in segments where !segment.isEmpty {
                    drawArea(segment.count == 1 ? [segment[0], NSPoint(x: segment[0].x + 1.5, y: segment[0].y)] : segment,
                             baseline: plot.minY, color: item.color, in: plot)
                }
            }
            drawTimeAxis(in: plot, range: range)
        }

        if style == .full, let hoverX, plot.contains(NSPoint(x: hoverX, y: plot.midY)) {
            drawHover(at: hoverX, in: plot, top: top)
        }
    }

    private func drawArea(_ points: [NSPoint], baseline: CGFloat, color: NSColor, in plot: NSRect) {
        guard let first = points.first, let last = points.last else { return }
        let line = NSBezierPath()
        line.move(to: first)
        for point in points.dropFirst() { line.line(to: point) }

        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: last.x, y: baseline))
        fill.line(to: NSPoint(x: first.x, y: baseline))
        fill.close()

        let above = first.y >= baseline || points.contains { $0.y > baseline }
        let gradient = NSGradient(colors: [color.withAlphaComponent(style == .full ? 0.32 : 0.28), color.withAlphaComponent(0.02)])
        gradient?.draw(in: fill, angle: above ? -90 : 90)

        color.setStroke()
        line.lineWidth = style == .full ? 1.6 : 1.3
        line.lineJoinStyle = .round
        line.stroke()
    }

    /// Mirrored charts put zero in the middle, so their labels count up towards both edges.
    private func drawGrid(in plot: NSRect, top: Double, mirrored: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.numberFont(10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for step in 0...4 {
            let y = plot.minY + plot.height * CGFloat(step) / 4
            NSColor.separatorColor.withAlphaComponent(step == (mirrored ? 2 : 0) ? 0.8 : 0.35).setFill()
            NSRect(x: plot.minX, y: y - 0.25, width: plot.width, height: 0.5).fill()
            let fraction = mirrored ? abs(Double(step) - 2) / 2 : Double(step) / 4
            if fraction > 0 {
                let label = valueFormatter(top * fraction) as NSString
                label.draw(at: NSPoint(x: plot.maxX + 6, y: y - 6), withAttributes: attributes)
            }
        }
    }

    private func drawTimeAxis(in plot: NSRect, range: ClosedRange<Date>) {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let formatter = span > 2 * 86_400 ? Self.dayFormatter : Self.timeFormatter
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let ticks = 5
        for step in 0...ticks {
            let date = range.lowerBound.addingTimeInterval(span * Double(step) / Double(ticks))
            let text = formatter.string(from: date) as NSString
            let size = text.size(withAttributes: attributes)
            let x = plot.minX + plot.width * CGFloat(step) / CGFloat(ticks)
            let clampedX = min(max(plot.minX, x - size.width / 2), plot.maxX - size.width)
            text.draw(at: NSPoint(x: clampedX, y: 1), withAttributes: attributes)
        }
    }

    private func drawHover(at x: CGFloat, in plot: NSRect, top: Double) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSRect(x: x - 0.5, y: plot.minY, width: 1, height: plot.height).fill()

        var lines: [(String, NSColor)] = []
        if !timedSeries.isEmpty, let range = timeRange ?? timedSeries.first.flatMap({ s in s.points.first.map { $0.date...(s.points.last?.date ?? $0.date) } }) {
            let span = range.upperBound.timeIntervalSince(range.lowerBound)
            let date = range.lowerBound.addingTimeInterval(span * Double((x - plot.minX) / plot.width))
            let formatter = span > 86_400 ? Self.hoverDateTimeFormatter : Self.hoverTimeFormatter
            lines.append((formatter.string(from: date), .secondaryLabelColor))
            for item in timedSeries {
                guard let nearest = item.points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
                      abs(nearest.date.timeIntervalSince(date)) < span / 40 else { continue }
                lines.append(((item.name.isEmpty ? "" : item.name + "  ") + valueFormatter(nearest.value), item.color))
            }
        } else {
            let span = visibleSpan
            let index = Int(((x - plot.minX) / plot.width * CGFloat(span - 1)).rounded())
            let secondsAgo = Double(span - 1 - index) * Monitor.interactiveInterval
            lines.append((secondsAgo < 1 ? "Now" : "\(Format.duration(secondsAgo)) ago", .secondaryLabelColor))
            for item in series {
                let offset = index - (span - min(span, item.values.count))
                guard offset >= 0, offset < item.values.count else { continue }
                lines.append(((item.name.isEmpty ? "" : item.name + "  ") + valueFormatter(item.values[offset]), item.color))
            }
        }
        guard lines.count > 1 else { return }

        let font = Theme.numberFont(11, weight: .medium)
        let sizes = lines.map { ($0.0 as NSString).size(withAttributes: [.font: font]) }
        let width = (sizes.map(\.width).max() ?? 0) + 16
        let height = CGFloat(lines.count) * 15 + 8
        var box = NSRect(x: x + 8, y: plot.maxY - height, width: width, height: height)
        if box.maxX > bounds.maxX { box.origin.x = x - 8 - width }
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        for (index, line) in lines.enumerated() {
            let y = box.maxY - 4 - CGFloat(index + 1) * 15
            (line.0 as NSString).draw(at: NSPoint(x: box.minX + 8, y: y + 1), withAttributes: [.font: font, .foregroundColor: line.1 == .secondaryLabelColor ? NSColor.secondaryLabelColor : NSColor.labelColor])
            if index > 0 {
                line.1.setFill()
                NSBezierPath(ovalIn: NSRect(x: box.minX + 2.5, y: y + 5, width: 4, height: 4)).fill()
            }
        }
    }

    private func drawEmpty(in plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = emptyText as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: attributes)
    }

    /// Rounds the axis maximum up to 1, 2 or 5 times a power of ten (fractions stay at 1.0).
    private func niceCeiling(_ value: Double) -> Double {
        if maxValue != nil { return value }
        guard value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        for step in [1.0, 2.0, 2.5, 5.0, 10.0] where step * base >= value {
            return step * base
        }
        return 10 * base
    }
}
