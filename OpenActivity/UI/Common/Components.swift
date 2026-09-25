//
//  Components.swift
//  OpenActivity
//
//  Cards, figures, bars and rings. Everything draws itself with layers or Core Graphics so it
//  follows light and dark appearance without assets.
//

import AppKit

// MARK: - Card

/// A rounded panel. Clickable when `onClick` is set.
class CardView: NSView {
    var onClick: (() -> Void)? {
        didSet { updateTracking() }
    }
    let content = NSStackView.vertical(spacing: 10)
    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    var contentInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16) {
        didSet {
            insetConstraints[0].constant = contentInsets.top
            insetConstraints[1].constant = contentInsets.left
            insetConstraints[2].constant = -contentInsets.right
            insetConstraints[3].constant = -contentInsets.bottom
            insetConstraints[4].constant = -contentInsets.bottom
        }
    }
    private var insetConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Theme.cardRadius
        layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        insetConstraints = [
            content.topAnchor.constraint(equalTo: topAnchor, constant: contentInsets.top),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInsets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInsets.right),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -contentInsets.bottom),
        ]
        // Hug the content so the card's height is never ambiguous. Kept below the default hugging of
        // the stacks inside, so when a grid row stretches the card the spare room goes below the
        // content instead of spreading out the lists in it.
        let hug = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -contentInsets.bottom)
        hug.priority = .init(NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
        content.setHuggingPriority(.defaultHigh, for: .vertical)
        insetConstraints.append(hug)
        NSLayoutConstraint.activate(insetConstraints)
    }

    convenience init(_ views: [NSView], spacing: CGFloat = 10) {
        self.init(frame: .zero)
        content.spacing = spacing
        views.forEach(content.addArrangedSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? NSColor.white.withAlphaComponent(isHovered ? 0.085 : 0.055) : NSColor.white
        layer?.backgroundColor = base.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(isHovered ? 0.12 : 0.07)).cgColor
        layer?.shadowOpacity = dark ? 0 : 0.05
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    private func updateTracking() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard onClick != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseUp(with: event)
            return
        }
        onClick()
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// A card header: colored symbol, title and an optional trailing accessory.
final class CardHeader: NSStackView {
    let titleLabel: NSTextField
    let accessoryLabel = NSTextField.caption()

    init(title: String, symbol: String? = nil, color: NSColor = .secondaryLabelColor) {
        titleLabel = .label(title, size: 13, weight: .semibold)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        if let symbol {
            let icon = NSImageView(image: NSImage.symbol(symbol, size: 12, weight: .semibold, color: color) ?? NSImage())
            addArrangedSubview(icon)
        }
        addArrangedSubview(titleLabel)
        addArrangedSubview(NSView.spacer())
        addArrangedSubview(accessoryLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Figures

/// A caption above a figure: "Reading" / "737 kB/s".
final class StatView: NSStackView {
    let titleLabel: NSTextField
    let valueLabel: NSTextField
    let detailLabel = NSTextField.label("", size: 11, color: .tertiaryLabelColor)

    init(title: String, value: String = "–", size: CGFloat = 15, dot: NSColor? = nil) {
        titleLabel = .caption(title)
        valueLabel = .number(value, size: size, weight: .semibold)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        if let dot {
            let row = NSStackView.horizontal([DotView(color: dot), titleLabel], spacing: 5)
            addArrangedSubview(row)
        } else {
            addArrangedSubview(titleLabel)
        }
        addArrangedSubview(valueLabel)
        addArrangedSubview(detailLabel)
        detailLabel.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ value: String, detail: String? = nil) {
        valueLabel.set(value)
        detailLabel.isHidden = detail == nil
        if let detail { detailLabel.set(detail) }
    }
}

/// A big figure with a small unit or caption beside it: "27 %".
final class BigFigureView: NSStackView {
    let valueLabel: NSTextField
    let unitLabel: NSTextField

    init(size: CGFloat = 30) {
        valueLabel = .number("–", size: size, weight: .semibold)
        unitLabel = .label("", size: size * 0.45, weight: .medium, color: .secondaryLabelColor)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 4
        addArrangedSubview(valueLabel)
        addArrangedSubview(unitLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ value: String, unit: String = "") {
        valueLabel.set(value)
        unitLabel.set(unit)
    }

    /// Splits "52.63 GB" into a figure and a unit.
    func update(splitting text: String) {
        if let space = text.lastIndex(of: " ") {
            update(String(text[..<space]), unit: String(text[text.index(after: space)...]))
        } else if text.hasSuffix("%") {
            update(String(text.dropLast()), unit: "%")
        } else {
            update(text)
        }
    }
}

final class DotView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor, diameter: CGFloat = 8) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

/// "● App      23.43 GB" legend rows.
final class LegendRow: NSStackView {
    let dot: DotView
    let nameLabel: NSTextField
    let valueLabel: NSTextField

    init(name: String, color: NSColor, value: String = "–") {
        dot = DotView(color: color)
        nameLabel = .label(name, size: 12, color: .secondaryLabelColor)
        valueLabel = .number(value, size: 12, weight: .medium)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        addArrangedSubview(dot)
        addArrangedSubview(nameLabel)
        addArrangedSubview(NSView.spacer(minWidth: 8))
        addArrangedSubview(valueLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Bars

/// A horizontal bar split into colored segments (memory by type, memory by app).
final class SegmentedBarView: NSView {
    struct Segment {
        var value: Double
        var color: NSColor
    }

    var segments: [Segment] = [] { didSet { needsDisplay = true } }
    /// When nil the segments fill the bar; otherwise they are drawn relative to this total.
    var total: Double?

    init(height: CGFloat = 10) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        track.fill()
        let sum = total ?? segments.reduce(0) { $0 + $1.value }
        guard sum > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        var x: CGFloat = 0
        for segment in segments where segment.value > 0 {
            let width = bounds.width * CGFloat(segment.value / sum)
            segment.color.setFill()
            NSRect(x: x, y: 0, width: max(0, width - 1.5), height: bounds.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A thin single-value bar, e.g. per-core load or a fan's speed.
final class MeterView: NSView {
    var value: Double = 0 { didSet { if oldValue != value { needsDisplay = true } } }
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var isVertical = false

    init(height: CGFloat? = 6, width: CGFloat? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let height { heightAnchor.constraint(equalToConstant: height).isActive = true }
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.width, bounds.height) / 2
        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let fraction = CGFloat(min(1, max(0, value)))
        guard fraction > 0 else { return }
        var filled = bounds
        if isVertical {
            filled.size.height = max(bounds.width, bounds.height * fraction)
        } else {
            filled.size.width = max(bounds.height, bounds.width * fraction)
        }
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// A ring gauge with a figure in the middle.
final class RingView: NSView {
    var value: Double = 0 { didSet { if oldValue != value { needsDisplay = true } } }
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 7
    let label = NSTextField.number("", size: 13, weight: .semibold)

    init(diameter: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.quaternaryLabelColor.withAlphaComponent(0.18).setStroke()
        track.stroke()

        let fraction = min(1, max(0, value))
        guard fraction > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
}

/// Small pill, used for ports and status tags.
final class PillView: NSView {
    let label: NSTextField
    var color: NSColor { didSet { needsDisplay = true; label.textColor = color } }

    init(_ text: String, color: NSColor = .secondaryLabelColor, monospaced: Bool = true) {
        self.color = color
        label = monospaced ? .number(text, size: 11, weight: .medium, color: color) : .label(text, size: 11, weight: .medium, color: color)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

// MARK: - Layout helpers

/// Lays cards out in equal-width columns, wrapping into rows.
final class GridStack: NSStackView {
    private let columns: Int

    init(columns: Int, spacing: CGFloat = Theme.cardSpacing) {
        self.columns = columns
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        self.spacing = spacing
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ items: [NSView]) {
        removeAllArrangedSubviews()
        var index = 0
        while index < items.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = spacing
            for column in 0..<columns {
                if index + column < items.count {
                    row.addArrangedSubview(items[index + column])
                } else {
                    row.addArrangedSubview(NSView())
                }
            }
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            // Cards in a row share the tallest height.
            let cards = row.arrangedSubviews.filter { $0 is CardView }
            for card in cards {
                card.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
            }
            index += columns
        }
    }
}

/// A flipped document view so scroll views start at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSScrollView {
    /// A vertically scrolling page whose content fills the width.
    static func page(with content: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: Theme.pagePadding, left: Theme.pagePadding, bottom: Theme.pagePadding, right: Theme.pagePadding)) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -insets.bottom),
        ])
        return scrollView
    }
}
