//
//  ShareCard.swift
//  OpenActivity
//
//  A 1200 × 630 px image of the Mac's current state, sized for social link previews.
//  Drawn offscreen with fixed colors so the result never depends on the app's appearance.
//

import AppKit

enum ShareCard {
    static let pixelSize = NSSize(width: 1200, height: 630)

    /// Renders the card at exactly 1200 × 630 pixels.
    static func render(snapshot: SystemSnapshot, dark: Bool) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // One point per pixel.
        rep.size = pixelSize

        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            // Flip so the layout below reads top to bottom.
            let cg = context.cgContext
            cg.translateBy(x: 0, y: pixelSize.height)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            Painter(snapshot: snapshot, palette: Palette(dark: dark)).draw()
            NSGraphicsContext.current?.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        let image = NSImage(size: pixelSize)
        image.addRepresentation(rep)
        return image
    }

    /// Writes a PNG to ~/Downloads/OpenActivity-<yyyy-MM-dd-HHmmss>.png.
    static func exportToDownloads(snapshot: SystemSnapshot, dark: Bool) throws -> URL {
        let image = render(snapshot: snapshot, dark: dark)
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileManager = FileManager.default
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let url = downloads.appendingPathComponent("OpenActivity-\(fileStamp.string(from: Date())).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

// MARK: - Palette

private struct Palette {
    let dark: Bool
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let glow: NSColor
    let panel: NSColor
    let panelBorder: NSColor
    let primary: NSColor
    let secondary: NSColor
    let tertiary: NSColor
    let track: NSColor
    let app, wired, compressed, cached, free: NSColor
    let cpu, gpu: NSColor

    init(dark: Bool) {
        self.dark = dark
        if dark {
            backgroundTop = NSColor(srgbRed: 0.106, green: 0.110, blue: 0.137, alpha: 1)
            backgroundBottom = NSColor(srgbRed: 0.059, green: 0.063, blue: 0.078, alpha: 1)
            glow = NSColor(srgbRed: 0.58, green: 0.36, blue: 0.95, alpha: 0.16)
            panel = NSColor(white: 1, alpha: 0.05)
            panelBorder = NSColor(white: 1, alpha: 0.08)
            primary = NSColor(white: 0.97, alpha: 1)
            secondary = NSColor(white: 1, alpha: 0.62)
            tertiary = NSColor(white: 1, alpha: 0.40)
            track = NSColor(white: 1, alpha: 0.10)
        } else {
            backgroundTop = NSColor(srgbRed: 0.980, green: 0.980, blue: 0.992, alpha: 1)
            backgroundBottom = NSColor(srgbRed: 0.918, green: 0.925, blue: 0.957, alpha: 1)
            glow = NSColor(srgbRed: 0.62, green: 0.40, blue: 0.98, alpha: 0.12)
            panel = NSColor(white: 1, alpha: 0.78)
            panelBorder = NSColor(white: 0, alpha: 0.06)
            primary = NSColor(white: 0.08, alpha: 1)
            secondary = NSColor(white: 0, alpha: 0.56)
            tertiary = NSColor(white: 0, alpha: 0.36)
            track = NSColor(white: 0, alpha: 0.07)
        }
        // The app's system colors, frozen for the requested appearance.
        func fixed(_ color: NSColor) -> NSColor { Self.resolve(color, dark: dark) }
        app = fixed(Theme.MemoryPart.app)
        wired = fixed(Theme.MemoryPart.wired)
        compressed = fixed(Theme.MemoryPart.compressed)
        cached = fixed(Theme.MemoryPart.cached)
        free = fixed(Theme.MemoryPart.free)
        cpu = fixed(Theme.color(for: .cpu))
        gpu = fixed(Theme.color(for: .gpu))
    }

    /// Resolves a dynamic color to plain sRGB components under a fixed appearance.
    static func resolve(_ color: NSColor, dark: Bool) -> NSColor {
        var result = color
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB) {
                result = NSColor(srgbRed: rgb.redComponent, green: rgb.greenComponent,
                                 blue: rgb.blueComponent, alpha: rgb.alphaComponent)
            }
        }
        return result
    }
}

// MARK: - Drawing

private struct Painter {
    let snapshot: SystemSnapshot
    let palette: Palette

    private let width: CGFloat = ShareCard.pixelSize.width
    private let height: CGFloat = ShareCard.pixelSize.height
    private let margin: CGFloat = 60
    /// Left column for memory and processor, right column for the app list.
    private var leftWidth: CGFloat { 560 }
    private var panelRect: NSRect { NSRect(x: 690, y: 162, width: width - 690 - margin, height: 408) }

    func draw() {
        drawBackground()
        drawHeader()
        drawMemory(top: 170)
        drawProcessors(top: 466)
        drawTopApps()
    }

    // MARK: Background

    private func drawBackground() {
        let bounds = NSRect(origin: .zero, size: ShareCard.pixelSize)
        NSGradient(starting: palette.backgroundTop, ending: palette.backgroundBottom)?.draw(in: bounds, angle: 90)
        // A soft glow behind the memory figure.
        let glow = NSGradient(colors: [palette.glow, palette.glow.withAlphaComponent(0)])
        glow?.draw(fromCenter: NSPoint(x: 220, y: 250), radius: 0, toCenter: NSPoint(x: 220, y: 250), radius: 520, options: [])
    }

    // MARK: Header

    private func drawHeader() {
        let machine = snapshot.machineName.isEmpty ? Monitor.productName : snapshot.machineName
        let title = text(machine, size: 36, weight: .bold, color: palette.primary)
        title.draw(with: NSRect(x: margin, y: 52, width: 760, height: 46), options: drawOptions)

        var details = [Monitor.productName]
        if !snapshot.cpu.modelName.isEmpty { details.append(snapshot.cpu.modelName) }
        if snapshot.memory.total > 0 { details.append(Format.memory(snapshot.memory.total)) }
        let subtitle = text(details.joined(separator: "  ·  "), size: 20, weight: .medium, color: palette.secondary)
        subtitle.draw(with: NSRect(x: margin, y: 100, width: 760, height: 28), options: drawOptions)

        // App name, small, top right.
        let brand = text("OpenActivity", size: 17, weight: .semibold, color: palette.secondary)
        let brandSize = brand.size()
        let iconSize: CGFloat = 26
        let brandX = width - margin - brandSize.width
        brand.draw(at: NSPoint(x: brandX, y: 62))
        if let icon = NSApp?.applicationIconImage {
            icon.draw(in: NSRect(x: brandX - iconSize - 8, y: 59, width: iconSize, height: iconSize),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let date = text(Self.dateFormatter.string(from: snapshot.date), size: 17, weight: .regular, color: palette.tertiary)
        date.draw(at: NSPoint(x: width - margin - date.size().width, y: 104))
    }

    // MARK: Memory

    private func drawMemory(top: CGFloat) {
        let memory = snapshot.memory
        caption("MEMORY IN USE").draw(at: NSPoint(x: margin, y: top))

        // Hero figure with a smaller unit: "41.2" + " GB".
        let used = Format.memory(memory.used)
        let parts = used.split(separator: " ", maxSplits: 1).map(String.init)
        let hero = NSMutableAttributedString(attributedString: text(parts[0], size: 96, weight: .bold, color: palette.primary, digits: true))
        if parts.count > 1 {
            hero.append(text(" " + parts[1], size: 44, weight: .semibold, color: palette.primary))
        }
        hero.append(text("  of \(Format.memory(memory.total))", size: 26, weight: .medium, color: palette.secondary))
        hero.draw(at: NSPoint(x: margin - 4, y: top + 14))

        // Stacked bar: app, wired, compressed, cached, free.
        let barRect = NSRect(x: margin, y: top + 142, width: leftWidth, height: 20)
        let segments: [(String, UInt64, NSColor)] = [
            ("App", memory.app, palette.app),
            ("Wired", memory.wired, palette.wired),
            ("Compressed", memory.compressed, palette.compressed),
            ("Cached", memory.cached, palette.cached),
            ("Free", memory.free, palette.free),
        ]
        let total = max(1, Double(memory.total))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: barRect, xRadius: barRect.height / 2, yRadius: barRect.height / 2).addClip()
        palette.track.setFill()
        barRect.fill()
        var x = barRect.minX
        for (_, bytes, color) in segments where bytes > 0 {
            let segmentWidth = barRect.width * CGFloat(Double(bytes) / total)
            color.setFill()
            // A hairline gap between segments keeps adjacent colors readable.
            NSRect(x: x, y: barRect.minY, width: max(0, segmentWidth - 2), height: barRect.height).fill()
            x += segmentWidth
        }
        NSGraphicsContext.restoreGraphicsState()

        // Legend under the bar, spread so the first starts and the last ends with the bar.
        let dotWidth: CGFloat = 18
        let entries = segments.map { segment in
            (name: text(segment.0, size: 15, weight: .medium, color: palette.secondary),
             value: text(Format.memory(segment.1), size: 19, weight: .semibold, color: palette.primary, digits: true),
             color: segment.2)
        }
        let widths = entries.map { dotWidth + max($0.name.size().width, $0.value.size().width) }
        let gap = max(12, (leftWidth - widths.reduce(0, +)) / CGFloat(entries.count - 1))
        var columnX = margin
        for (entry, columnWidth) in zip(entries, widths) {
            entry.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: columnX, y: top + 188, width: 11, height: 11)).fill()
            entry.name.draw(at: NSPoint(x: columnX + dotWidth, y: top + 182))
            entry.value.draw(at: NSPoint(x: columnX + dotWidth, y: top + 204))
            columnX += columnWidth + gap
        }
    }

    // MARK: CPU and GPU

    private func drawProcessors(top: CGFloat) {
        let cpu = snapshot.cpu
        var cores: [String] = []
        if cpu.performanceCores > 0 || cpu.efficiencyCores > 0 {
            cores.append("\(cpu.performanceCores)P + \(cpu.efficiencyCores)E cores")
        } else if cpu.logicalCores > 0 {
            cores.append("\(cpu.logicalCores) cores")
        }
        if let load = cpu.loadAverage.first, load > 0 { cores.append(String(format: "Load %.2f", load)) }
        drawRing(title: "CPU", detail: cores, value: cpu.total, color: palette.cpu,
                 origin: NSPoint(x: margin, y: top))

        var gpuDetail: [String] = []
        if let count = snapshot.gpu.coreCount { gpuDetail.append("\(count) cores") }
        if snapshot.gpu.memoryInUse > 0 { gpuDetail.append("\(Format.memory(snapshot.gpu.memoryInUse)) in use") }
        drawRing(title: "GPU", detail: gpuDetail, value: snapshot.gpu.utilization, color: palette.gpu,
                 origin: NSPoint(x: margin + leftWidth / 2 + 10, y: top))
    }

    private func drawRing(title: String, detail: [String], value: Double, color: NSColor, origin: NSPoint) {
        let diameter: CGFloat = 104
        let lineWidth: CGFloat = 11
        let rect = NSRect(x: origin.x, y: origin.y, width: diameter, height: diameter).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let center = NSPoint(x: rect.midX, y: rect.midY)

        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        palette.track.setStroke()
        track.stroke()

        let fraction = min(1, max(0, value.isFinite ? value : 0))
        if fraction > 0.005 {
            // Clockwise from twelve o'clock in the flipped context.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: rect.width / 2, startAngle: -90, endAngle: -90 + 360 * fraction, clockwise: false)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }

        let figure = text(Format.percent(fraction), size: 27, weight: .bold, color: palette.primary, digits: true)
        let size = figure.size()
        figure.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))

        // Title and up to two detail lines, centered on the ring.
        let labelX = origin.x + diameter + 20
        let lines = Array(detail.prefix(2))
        var y = center.y - (28 + CGFloat(lines.count) * 21) / 2
        text(title, size: 22, weight: .bold, color: palette.primary).draw(at: NSPoint(x: labelX, y: y))
        y += 30
        for line in lines {
            text(line, size: 15, weight: .medium, color: palette.secondary)
                .draw(with: NSRect(x: labelX, y: y, width: 150, height: 20), options: drawOptions)
            y += 21
        }
    }

    // MARK: Top apps

    private func drawTopApps() {
        let panel = panelRect
        let path = NSBezierPath(roundedRect: panel, xRadius: 22, yRadius: 22)
        palette.panel.setFill()
        path.fill()
        palette.panelBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        let inset: CGFloat = 28
        caption("TOP APPS BY MEMORY").draw(at: NSPoint(x: panel.minX + inset, y: panel.minY + 26))

        let apps = snapshot.apps
            .filter { !$0.isSystem && $0.memory > 0 }
            .sorted { $0.memory > $1.memory }
            .prefix(5)
        let largest = Double(apps.first?.memory ?? 1)
        let rowHeight: CGFloat = 66
        var y = panel.minY + 64

        if apps.isEmpty {
            text("No apps measured yet", size: 18, weight: .medium, color: palette.tertiary)
                .draw(at: NSPoint(x: panel.minX + inset, y: y + 10))
            return
        }

        for app in apps {
            let iconRect = NSRect(x: panel.minX + inset, y: y + 8, width: 44, height: 44)
            Self.cardIcon(for: app).draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])

            let figure = text(Format.memory(app.memory), size: 20, weight: .semibold, color: palette.primary, digits: true)
            let figureWidth = figure.size().width
            let right = panel.maxX - inset
            figure.draw(at: NSPoint(x: right - figureWidth, y: y + 10))

            let nameX = iconRect.maxX + 16
            text(app.name, size: 20, weight: .medium, color: palette.primary)
                .draw(with: NSRect(x: nameX, y: y + 10, width: right - figureWidth - nameX - 16, height: 26), options: drawOptions)

            // A thin bar relative to the largest app.
            let barRect = NSRect(x: nameX, y: y + 42, width: right - nameX, height: 5)
            palette.track.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5).fill()
            var filled = barRect
            filled.size.width = max(5, barRect.width * CGFloat(Double(app.memory) / largest))
            palette.app.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5).fill()

            y += rowHeight
        }
    }

    // MARK: Text

    private var drawOptions: NSString.DrawingOptions { [.usesLineFragmentOrigin, .truncatesLastVisibleLine] }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, digits: Bool = false) -> NSAttributedString {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func caption(_ string: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(attributedString: text(string, size: 14, weight: .semibold, color: palette.tertiary))
        attributed.addAttribute(.kern, value: 1.4, range: NSRange(location: 0, length: attributed.length))
        return attributed
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    /// The app's own icon file. NSWorkspace icons follow the system icon style (dark or tinted),
    /// which would put dark icons on the light card.
    private static func cardIcon(for app: AppGroup) -> NSImage {
        if let path = app.bundlePath,
           let bundle = Bundle(path: path),
           let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let name = (file as NSString).pathExtension.isEmpty ? file + ".icns" : file
            if let url = bundle.resourceURL?.appendingPathComponent(name), let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return AppIcons.icon(for: app)
    }
}
