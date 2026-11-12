import AppKit
import MicLinkCore

final class SignalView: NSView {
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
    func begin(playback: Bool = false) {
        timer?.invalidate(); history = SignalHistory(); displayedDB = -72
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
        (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let card = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill(); card.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke(); card.lineWidth = 1; card.stroke()
        let title = playback ? "回放电平" : "输入电平"
        text(title, x: 16, y: 12, size: 13, color: .labelColor, weight: .semibold)
        let phase = active ? (history.windows.isEmpty ? "等待音频" : (playback ? "正在回放" : "正在接收")) : (history.windows.isEmpty ? "等待音频" : "已停止 · 波形保留")
        text(phase, x: 94, y: 14)
        text("RMS \(active ? dbText(displayedDB) : "—") dBFS", x: bounds.width - 278, y: 13, color: .labelColor)
        let peakDB = SignalHistory.decibels(history.sessionPeak)
        text("峰值 \(dbText(peakDB)) dBFS", x: bounds.width - 137, y: 13, color: peakDB >= -3 ? .systemRed : .secondaryLabelColor)
        let left: CGFloat = 16, width = bounds.width - 32
        let meter = NSRect(x: left, y: 39, width: width, height: 9)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill(); NSBezierPath(roundedRect: meter, xRadius: 4, yRadius: 4).fill()
        if active && displayedDB > -60 {
            color(displayedDB).setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: 39, width: width * fraction(displayedDB), height: 9), xRadius: 4, yRadius: 4).fill()
        }
        for db: Float in [-60,-36,-12,0] {
            let x = left + width * fraction(db)
            text("\(Int(db))", x: min(bounds.width-26, x-5), y: 52, size: 9)
        }
        let center: CGFloat = 116, half: CGFloat = 32
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        let grid = NSBezierPath(); grid.move(to: NSPoint(x: left, y: center)); grid.line(to: NSPoint(x: left+width, y: center)); grid.stroke()
        for i in 0...4 {
            let x = left + CGFloat(i) * width / 4
            let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: center-half)); line.line(to: NSPoint(x: x, y: center+half)); line.setLineDash([2,4], count: 2, phase: 0); line.stroke()
        }
        let step = width / CGFloat(history.capacity)
        for (i, window) in history.windows.enumerated() {
            let x = left + CGFloat(history.capacity-history.windows.count+i) * step
            let height = max(1, fraction(window.peakDB) * half * 2)
            color(window.peakDB).withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: center-height/2, width: max(1,step-1), height: height), xRadius: 1, yRadius: 1).fill()
        }
        text("最近 4 秒 · 对数幅度包络", x: left, y: 158)
        text(peakDB >= -3 ? "接近满幅，请留意削波" : "绿：正常  黄：较强  红：接近满幅", x: bounds.width-235, y: 158, color: peakDB >= -3 ? .systemRed : .secondaryLabelColor)
    }
    deinit { timer?.invalidate() }
}
