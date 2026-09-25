//
//  SoundViewController.swift
//  OpenActivity
//
//  A volume slider for every app that is playing sound.
//

import AppKit

final class SoundViewController: NSViewController, LivePage {
    private let list = NSStackView.vertical(spacing: 0)
    private let emptyLabel = NSTextField.wrapping("No app is playing sound right now. Apps show up here as soon as they do, and keep the volume you gave them.", size: 13, color: .secondaryLabelColor)
    private var rows: [Int32: SoundRow] = [:]
    private var order: [Int32] = []

    override func loadView() {
        let page = NSStackView.vertical(spacing: Theme.cardSpacing, alignment: .leading)
        let title = NSTextField.label("Volume per app", size: 20, weight: .bold)
        let subtitle = NSTextField.wrapping("Turn one app down without touching the others. Sound passes through your Mac only; nothing is recorded.", size: 12)
        page.addArrangedSubview(NSStackView.vertical([title, subtitle], spacing: 4))

        let resetButton = NSButton(title: "Reset All", target: self, action: #selector(resetAll))
        resetButton.bezelStyle = .rounded
        let header = CardHeader(title: "Apps playing sound", symbol: "speaker.wave.2.fill", color: Theme.color(for: .sound))
        header.addArrangedSubview(resetButton)
        let card = CardView([header, list, emptyLabel])
        list.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
        emptyLabel.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
        page.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        subtitle.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true

        view = NSScrollView.page(with: page)
        AudioVolumeController.shared.onChange = { [weak self] in self?.reload() }
        reload()
    }

    func update(with snapshot: SystemSnapshot) {
        reload()
    }

    private func reload() {
        let apps = AudioVolumeController.shared.audioApps()
        emptyLabel.isHidden = !apps.isEmpty
        let pids = apps.map(\.pid)
        if pids != order {
            order = pids
            list.removeAllArrangedSubviews()
            var next: [Int32: SoundRow] = [:]
            for app in apps {
                let row = rows[app.pid] ?? SoundRow(pid: app.pid)
                next[app.pid] = row
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            rows = next
        }
        for app in apps { rows[app.pid]?.configure(app) }
    }

    @objc private func resetAll() {
        AudioVolumeController.shared.resetAll()
        reload()
    }
}

private final class SoundRow: NSView {
    let pid: Int32
    private let icon = NSImageView()
    private let name = NSTextField.label("", size: 13, weight: .medium)
    private let state = NSTextField.caption()
    private let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let muteButton = NSButton()
    private let value = NSTextField.number("", size: 12, color: .secondaryLabelColor)

    init(pid: Int32) {
        self.pid = pid
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        muteButton.bezelStyle = .regularSquare
        muteButton.isBordered = false
        muteButton.target = self
        muteButton.action = #selector(toggleMute(_:))
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let text = NSStackView.vertical([name, state], spacing: 1)
        text.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let stack = NSStackView.horizontal([icon, text, muteButton, slider, value], spacing: 10)
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ app: AudioApp) {
        let running = NSRunningApplication(processIdentifier: app.pid)
        icon.image = running?.icon ?? AppIcons.icon(bundlePath: running?.bundleURL?.path)
        name.set(app.name)
        state.set(app.isPlaying ? "Playing" : "Quiet")
        let dragging = window?.firstResponder === slider && NSEvent.pressedMouseButtons & 1 != 0
        if !dragging { slider.floatValue = app.volume }
        slider.isEnabled = !app.isMuted
        value.set(app.isMuted ? "Muted" : Format.percent(Double(app.volume)))
        let symbol = app.isMuted ? "speaker.slash.fill" : app.volume < 0.34 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
        muteButton.image = NSImage.symbol(symbol, size: 14, color: app.isMuted ? .systemRed : .secondaryLabelColor)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        AudioVolumeController.shared.setVolume(sender.floatValue, for: pid)
        value.set(Format.percent(Double(sender.floatValue)))
    }

    @objc private func toggleMute(_ sender: NSButton) {
        let muted = AudioVolumeController.shared.audioApps().first { $0.pid == pid }?.isMuted ?? false
        AudioVolumeController.shared.setMuted(!muted, for: pid)
        if let app = AudioVolumeController.shared.audioApps().first(where: { $0.pid == pid }) { configure(app) }
    }
}
