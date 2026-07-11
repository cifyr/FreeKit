import AppKit
import FreeSpeechCore

enum HUDState {
    case recording(AudioSource)
    case transcribing
    case processing
    case success
    case error(String)
}

// Non-activating floating panel, Greenlight-red, in two user-selectable sizes
// (design handoff): Compact bar 180x32 with micro-label text states, and Micro
// capsule 76x26 whose states collapse to glyphs. The animated waveform IS the
// HUD while listening; states crossfade, never hard-cut.
final class HUDController {
    private let panel: NSPanel
    private let card = NSView()
    private let innerHairline = CALayer()
    private let waveRow = NSView()
    private let statusRow = NSView()
    private let waveform = WaveformLineView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var dismissTimer: DispatchWorkItem?
    private var waveConstraints: [NSLayoutConstraint] = []

    var onAutoDismiss: (() -> Void)?
    var hudPosition: HUDPosition = .bottomCenter
    var hudStyle: HUDStyle = .compactBar {
        didSet { if hudStyle != oldValue { applyStyle() } }
    }

    private var size: NSSize {
        hudStyle == .microCapsule ? NSSize(width: 76, height: 26) : NSSize(width: 180, height: 32)
    }
    private var cornerRadius: CGFloat {
        hudStyle == .microCapsule ? 13 : 12
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 180, height: 32)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        card.wantsLayer = true
        card.layer?.backgroundColor = DS.glass.cgColor
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = DS.line.cgColor
        // Inset hairline: a faint inner light edge so the glass reads over any wallpaper.
        innerHairline.borderColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05).cgColor
        innerHairline.borderWidth = 0.5
        innerHairline.cornerCurve = .continuous
        card.layer?.addSublayer(innerHairline)

        for row in [waveRow, statusRow] {
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
        }
        waveform.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.backgroundColor = DS.accent.cgColor
        dot.layer?.cornerRadius = 3

        waveRow.addSubview(waveform)
        statusRow.addSubview(dot)
        statusRow.addSubview(label)
        panel.contentView = card
        applyStyle()
    }

    // Rebuilds metrics when the style changes; the panel is repositioned on show.
    private func applyStyle() {
        card.frame = NSRect(origin: .zero, size: size)
        card.layer?.cornerRadius = cornerRadius
        innerHairline.frame = card.bounds.insetBy(dx: 0.5, dy: 0.5)
        innerHairline.cornerRadius = cornerRadius - 0.5

        NSLayoutConstraint.deactivate(waveConstraints)
        let pad: CGFloat = hudStyle == .microCapsule ? 10 : 12
        waveform.configure(
            barCount: hudStyle == .microCapsule ? 9 : 22,
            gap: hudStyle == .microCapsule ? 2.5 : 2)
        waveConstraints = [
            waveRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            waveRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            waveRow.topAnchor.constraint(equalTo: card.topAnchor),
            waveRow.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            statusRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            statusRow.topAnchor.constraint(equalTo: card.topAnchor),
            statusRow.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            sourceTag.centerYAnchor.constraint(equalTo: waveRow.centerYAnchor),
            waveform.centerYAnchor.constraint(equalTo: waveRow.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: hudStyle == .microCapsule ? 14 : 18),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
        ]
        if hudStyle == .microCapsule {
            // Glyph-only: the dot or checkmark sits alone, centered.
            waveConstraints += [
                waveform.widthAnchor.constraint(equalToConstant: 48),
                waveform.centerXAnchor.constraint(equalTo: waveRow.centerXAnchor),
                dot.centerXAnchor.constraint(equalTo: statusRow.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
                label.centerXAnchor.constraint(equalTo: statusRow.centerXAnchor),
            ]
        } else {
            waveConstraints += [
                waveform.leadingAnchor.constraint(equalTo: waveRow.leadingAnchor, constant: pad),
                waveform.trailingAnchor.constraint(equalTo: waveRow.trailingAnchor, constant: -pad),
                dot.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
                dot.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
                label.centerXAnchor.constraint(equalTo: statusRow.centerXAnchor, constant: 4),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            ]
        }
        NSLayoutConstraint.activate(waveConstraints)
    }

    func show(_ state: HUDState) {
        dismissTimer?.cancel()
        dismissTimer = nil

        switch state {
        case .recording:
            showLiveWaveform()
        case .transcribing:
            showProcessingWaveform()
        case .processing:
            showProcessingWaveform()
        case .success:
            if hudStyle == .microCapsule {
                showGlyph("\u{2713}", color: DS.paper)
            } else {
                showStatus(text: "Inserted", color: DS.paper, dotStyle: .hidden)
            }
            scheduleDismiss(after: 0.8)
        case .error(let message):
            if hudStyle == .microCapsule {
                card.layer?.borderColor = DS.accent.withAlphaComponent(0.55).cgColor
                showStatus(text: "", color: DS.accent, dotStyle: .solid)
            } else {
                showStatus(text: message, color: DS.accent, dotStyle: .hidden)
            }
            scheduleDismiss(after: 3.5)
        }

        position()
        if !panel.isVisible {
            animateIn()
        }
    }

    func updateLevel(_ level: Float) {
        waveform.push(level: level)
    }

    func dismiss() {
        dismissTimer?.cancel()
        dismissTimer = nil
        waveform.stopAnimating()
        panel.orderOut(nil)
    }

    // MARK: - State rendering

    private func showLiveWaveform() {
        card.layer?.borderColor = DS.line.cgColor
        waveform.startLiveLevels()
        crossfade(toWave: true)
    }

    private func showProcessingWaveform() {
        card.layer?.borderColor = DS.line.cgColor
        waveform.startAutomaticWave()
        crossfade(toWave: true)
    }

    private enum DotStyle { case hidden, pulsing, solid }

    private func showStatus(text: String, color: NSColor, dotStyle: DotStyle) {
        card.layer?.borderColor = hudStyle == .microCapsule && dotStyle == .solid
            ? DS.accent.withAlphaComponent(0.55).cgColor : DS.line.cgColor
        waveform.stopAnimating()
        label.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .kern: 1.2,
                .foregroundColor: color,
            ])
        label.isHidden = text.isEmpty
        dot.isHidden = dotStyle == .hidden
        dot.layer?.removeAllAnimations()
        dot.layer?.backgroundColor = DS.accent.cgColor
        dot.layer?.cornerRadius = 3
        if dotStyle == .pulsing {
            // Breathes symmetrically: opacity .35->1, scale .82->1, 1.4s round trip.
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.35
            opacity.toValue = 1.0
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.82
            scale.toValue = 1.0
            let group = CAAnimationGroup()
            group.animations = [opacity, scale]
            group.duration = 0.7
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            dot.layer?.add(group, forKey: "pulse")
        }
        crossfade(toWave: false)
    }

    private func showGlyph(_ glyph: String, color: NSColor) {
        card.layer?.borderColor = DS.line.cgColor
        waveform.stopAnimating()
        dot.isHidden = true
        dot.layer?.removeAllAnimations()
        label.isHidden = false
        label.attributedStringValue = NSAttributedString(
            string: glyph,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: color,
            ])
        crossfade(toWave: false)
    }

    // The waveform and status swap by opacity, never a hard cut.
    private func crossfade(toWave: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DS.hudCrossfade
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            waveRow.animator().alphaValue = toWave ? 1 : 0
            statusRow.animator().alphaValue = toWave ? 0 : 1
        }
    }

    private func animateIn() {
        panel.alphaValue = 0
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                self.waveform.stopAnimating()
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.onAutoDismiss?()
            })
        }
        dismissTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let margin: CGFloat = 24
        let origin: NSPoint
        switch hudPosition {
        case .bottomCenter:
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 120)
        case .topCenter:
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - margin)
        case .bottomLeft:
            origin = NSPoint(x: frame.minX + margin, y: frame.minY + margin)
        case .bottomRight:
            origin = NSPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        card.frame = NSRect(origin: .zero, size: size)
        innerHairline.frame = card.bounds.insetBy(dx: 0.5, dy: 0.5)
    }
}

// During capture, bars only respond to measured audio. Once capture stops and
// transcription begins, the same surface switches to a self-running wave.
final class WaveformLineView: NSView {
    private enum Mode { case liveLevels, automatic }

    private var barCount = 22
    private var gap: CGFloat = 2
    private var phase: Double = 0
    private var envelope: CGFloat = 0
    private var timer: Timer?
    private var mode: Mode = .liveLevels

    private static let frameInterval: TimeInterval = 1.0 / 30.0

    func configure(barCount: Int, gap: CGFloat) {
        self.barCount = barCount
        self.gap = gap
        needsDisplay = true
    }

    func push(level: Float) {
        DispatchQueue.main.async {
            // Fast attack, slow release, so speech feels immediate but not jittery.
            let target = CGFloat(level.squareRoot()) * 1.8
            self.envelope = target > self.envelope
                ? self.envelope * 0.4 + target * 0.6
                : self.envelope * 0.85
        }
    }

    func startLiveLevels() {
        mode = .liveLevels
        envelope = 0
        phase = 0
        startTimer()
    }

    func startAutomaticWave() {
        mode = .automatic
        envelope = 0
        phase = 0
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.mode == .automatic { self.phase += Self.frameInterval }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard barCount > 1 else { return }
        let barWidth = (bounds.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
        guard barWidth > 0 else { return }
        DS.accent.setFill()
        for i in 0..<barCount {
            let p = Double(i) / Double(barCount - 1)
            let window = 0.4 + 0.6 * sin(.pi * p)
            let v: Double
            switch mode {
            case .liveLevels:
                let strength = min(1.0, Double(envelope) * 3.2)
                let texture = 0.56 + 0.22 * sin(p * .pi * 5.0)
                    + 0.18 * cos(p * .pi * 8.0)
                v = max(0.05, texture * window * strength)
            case .automatic:
                let s1 = sin(p * .pi * 2 * 1.4 + phase * 2.1)
                let s2 = sin(p * .pi * 2 * 0.6 - phase * 1.15)
                v = max(0.05, (0.5 + 0.26 * s1 + 0.24 * s2) * window)
            }
            let h = max(2.5, CGFloat(v) * bounds.height)
            let rect = NSRect(
                x: CGFloat(i) * (barWidth + gap),
                y: (bounds.height - h) / 2,
                width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
