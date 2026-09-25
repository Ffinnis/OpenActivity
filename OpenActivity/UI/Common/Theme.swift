//
//  Theme.swift
//  OpenActivity
//
//  Colors, fonts and small view factories shared by every screen.
//

import AppKit
import UniformTypeIdentifiers

enum Theme {
    static func color(for metric: Metric) -> NSColor {
        switch metric {
        case .cpu: return .systemBlue
        case .memory: return .systemPurple
        case .disk: return .systemOrange
        case .network: return .systemTeal
        case .gpu: return .systemPink
        case .battery: return .systemGreen
        case .sensors: return .systemRed
        case .sound: return .systemIndigo
        case .projects: return .systemBrown
        case .overview: return .controlAccentColor
        }
    }

    /// Second series on two-series charts (upload, disk writes, system CPU).
    static func secondaryColor(for metric: Metric) -> NSColor {
        switch metric {
        case .network: return .systemIndigo
        case .disk: return .systemRed
        case .cpu: return .systemCyan
        default: return color(for: metric).withAlphaComponent(0.6)
        }
    }

    enum MemoryPart {
        static let app = NSColor.systemPurple
        static let wired = NSColor.systemOrange
        static let compressed = NSColor.systemPink
        static let cached = NSColor.systemTeal
        static let free = NSColor.tertiaryLabelColor
    }

    static let cardRadius: CGFloat = 12
    static let pagePadding: CGFloat = 24
    static let cardSpacing: CGFloat = 14

    static func valueFont(_ size: CGFloat = 26) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }

    static func numberFont(_ size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// Green, orange or red for how loaded something is (0...1).
    static func loadColor(_ fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.6: return .systemGreen
        case ..<0.85: return .systemOrange
        default: return .systemRed
        }
    }

    static func temperatureColor(_ celsius: Double) -> NSColor {
        switch celsius {
        case ..<60: return .systemGreen
        case ..<85: return .systemOrange
        default: return .systemRed
        }
    }
}

// MARK: - Label factories

extension NSTextField {
    static func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func number(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = self.label(text, size: size, weight: weight, color: color)
        label.font = Theme.numberFont(size, weight: weight)
        return label
    }

    static func caption(_ text: String = "") -> NSTextField {
        label(text, size: 11, weight: .medium, color: .secondaryLabelColor)
    }

    static func wrapping(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.isSelectable = false
        return label
    }

    /// Updates text only when it changed, avoiding needless relayout on every sample.
    func set(_ text: String) {
        if stringValue != text { stringValue = text }
    }
}

extension NSStackView {
    static func vertical(_ views: [NSView] = [], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = alignment
        return stack
    }

    static func horizontal(_ views: [NSView] = [], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = alignment
        return stack
    }

    func removeAllArrangedSubviews() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }

    static func spacer(minWidth: CGFloat = 0) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentHuggingPriority(.init(1), for: .vertical)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        return view
    }
}

extension NSImage {
    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let color { configuration = configuration.applying(.init(paletteColors: [color])) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

// MARK: - App icons

enum AppIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for app: AppGroup) -> NSImage {
        icon(bundlePath: app.bundlePath, executablePath: app.processes.first?.path, isSystem: app.id == AppGrouper.systemGroupID)
    }

    static func icon(bundlePath: String?, executablePath: String? = nil, isSystem: Bool = false) -> NSImage {
        let key = (isSystem ? "system" : bundlePath ?? executablePath ?? "generic") as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage
        if isSystem {
            image = (NSImage(named: NSImage.computerName)?.copy() as? NSImage) ?? NSWorkspace.shared.icon(for: .applicationBundle)
        } else if let bundlePath {
            image = NSWorkspace.shared.icon(forFile: bundlePath)
        } else if let executablePath {
            image = NSWorkspace.shared.icon(forFile: executablePath)
        } else {
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key)
        return image
    }
}
