import AppKit
import MicLinkCore

final class SignalView: NSView {
    var compactMeter = false { didSet { if oldValue != compactMeter { needsDisplay = true } } }
    var emphasizeText = false { didSet { if oldValue != emphasizeText { needsDisplay = true } } }
    private var history = SignalHistory()
    private var timer: Timer?
    private var active = false, playback = false
    private var lastAudio = Date.distantPast
    private var displayedDB: Float = -72
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("输入电平与最近四秒波形")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func begin(playback: Bool = false, sampleRate: Double = 48000) {
        timer?.invalidate(); history = SignalHistory(sampleRate: sampleRate); displayedDB = -72
        active = true; self.playback = playback; lastAudio = .distantPast
        timer = Timer(timeInterval: 1.0/30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common); needsDisplay = true
    }
    func append(_ samples: [Float]) {
        history.append(samples); lastAudio = Date()
    }
    func end() {
        active = false; timer?.invalidate(); timer = nil; displayedDB = -72
        needsDisplay = true; updateAccessibility()
    }
    private func tick() {
        let target = Date().timeIntervalSince(lastAudio) < 0.25 ? max(-72, history.windows.last?.rmsDB ?? -72) : -72
        displayedDB += (target - displayedDB) * (target > displayedDB ? 0.65 : 0.18)
        needsDisplay = true; updateAccessibility()
    }
    private func dbText(_ db: Float) -> String { db <= -72 ? "−∞" : String(format: "%.1f", db) }
    private func updateAccessibility() {
        setAccessibilityValue("\(playback ? "回放" : "输入")电平 \(dbText(displayedDB)) dBFS，峰值 \(dbText(SignalHistory.decibels(history.sessionPeak))) dBFS")
    }
    private func color(_ db: Float) -> NSColor {
        db >= -3 ? .systemRed : db >= -12 ? .systemYellow : .systemGreen
    }
    private func fraction(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }
    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat = 11, color: NSColor = .secondaryLabelColor, weight: NSFont.Weight = .regular) {
        (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: emphasizeText ? .semibold : weight), .foregroundColor: color])
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if compactMeter { drawCompactMeter(); return }
        let left: CGFloat = 4, width = max(0, bounds.width - 8)
        let graphHeight = max(60, bounds.height - 72)
        let graph = NSRect(x: left, y: 0, width: width, height: graphHeight)
        let graphPath = NSBezierPath(roundedRect: graph, xRadius: 8, yRadius: 8)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        (reduceTransparency ? NSColor.controlBackgroundColor : NSColor.labelColor.withAlphaComponent(contrast ? 0.08 : 0.025)).setFill(); graphPath.fill()
        NSColor.separatorColor.withAlphaComponent(contrast ? 1 : 0.5).setStroke(); graphPath.lineWidth = 0.7; graphPath.stroke()
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        grid.setLineDash([2, 3], count: 2, phase: 0)
        for i in 1..<12 {
            let x = left + width * CGFloat(i) / 12
            grid.move(to: NSPoint(x: x, y: 1)); grid.line(to: NSPoint(x: x, y: graphHeight - 1))
        }
        NSColor.labelColor.withAlphaComponent(contrast ? 0.3 : 0.08).setStroke(); grid.stroke()
        let center = graphHeight / 2, half = graphHeight / 2 - 14
        let baseline = NSBezierPath(); baseline.lineWidth = 0.7
        baseline.move(to: NSPoint(x: left+4, y: center)); baseline.line(to: NSPoint(x: left+width-4, y: center))
        NSColor.labelColor.withAlphaComponent(0.16).setStroke(); baseline.stroke()
        if active && !history.windows.isEmpty {
            let step = (width - 8) / CGFloat(history.capacity)
            for (i, window) in history.windows.enumerated() {
                let x = left + 4 + CGFloat(history.capacity-history.windows.count+i) * step
                let height = max(1, fraction(window.peakDB) * half * 2)
                (window.peakDB >= -3 ? NSColor.systemRed : NSColor.controlAccentColor).withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: center-height/2, width: max(1,step-1), height: height), xRadius: 1, yRadius: 1).fill()
            }
        } else {
            let label = active ? "等待音频" : "尚未接收音频"
            let labelWidth = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            text(label, x: left + (width-labelWidth)/2, y: center + 12, size: 12)
        }
        text("RMS \(active ? dbText(displayedDB) : "—") dBFS", x: left, y: graphHeight + 12)
        let peakDB = SignalHistory.decibels(history.sessionPeak)
        text("峰值 \(dbText(peakDB)) dBFS", x: max(left, bounds.width - 112), y: graphHeight + 12)
        let segments = 40, gap: CGFloat = 1.5
        let segmentWidth = max(1, (width - CGFloat(segments-1) * gap) / CGFloat(segments))
        for i in 0..<segments {
            let lit = active && displayedDB > -60 && CGFloat(i) / CGFloat(segments) < fraction(displayedDB)
            (lit ? color(-60 + Float(i) / Float(segments) * 60) : (contrast ? NSColor.separatorColor : NSColor.quaternaryLabelColor)).setFill()
            NSBezierPath(roundedRect: NSRect(x: left + CGFloat(i) * (segmentWidth+gap), y: graphHeight + 37, width: segmentWidth, height: 8), xRadius: 1.5, yRadius: 1.5).fill()
        }
        for db: Float in [-60, -36, -12, 0] {
            let x = left + width * fraction(db)
            text("\(Int(db))", x: min(bounds.width-16, max(left, x-5)), y: graphHeight + 53, size: 10)
        }
    }
    private func drawCompactMeter() {
        let count = max(8, Int(bounds.width / 27)), gap: CGFloat = 4
        let w = max(1, (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count))
        for i in 0..<count {
            let db = -60 + Float(i) / Float(count) * 60
            let lit = active && displayedDB > -60 && CGFloat(i) / CGFloat(count) < fraction(displayedDB)
            let idle = i >= count - 3 ? NSColor.systemRed.withAlphaComponent(0.13) : NSColor.labelColor.withAlphaComponent(0.09)
            (lit ? color(db) : idle).setFill()
            NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * (w + gap), y: 2, width: w, height: 20), xRadius: 4, yRadius: 4).fill()
        }
        for db: Float in [-50, -30, -12, 0] {
            let label = db == -50 ? "-50 dB" : String(Int(db))
            let x: CGFloat = db == -50 ? 0 : db == 0 ? max(0, bounds.width - 7) : bounds.width * fraction(db) - 5
            text(label, x: x, y: 28, size: 8, color: .tertiaryLabelColor)
        }
    }
    deinit { timer?.invalidate() }
}
