import AppKit
import MicLinkCore

final class ButtonMonitorView: NSView {
    private var counts: [MicButton: Int] = [:]
    private var dates: [MicButton: Date] = [:]
    private var values: [MicButton: String] = [:]
    private var active = false
    private let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("实体按键反馈")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func begin() { counts = [:]; dates = [:]; values = [:]; active = true; update() }
    func end() { active = false; update() }
    func receive(_ event: MicButtonEvent) {
        counts[event.button, default: 0] += 1; dates[event.button] = Date()
        values[event.button] = String(format: "%02X → %02X", event.previousValue, event.value)
        update()
        DispatchQueue.main.asyncAfter(deadline: .now()+0.85) { [weak self] in self?.needsDisplay = true }
    }
    private func update() {
        needsDisplay = true
        setAccessibilityValue("电源键候选 \(counts[.power, default: 0]) 次，录音键候选 \(counts[.record, default: 0]) 次，连接键候选 \(counts[.link, default: 0]) 次。\(active ? "连接中，持续监听" : "未监听")")
    }
    private func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat = 11, color: NSColor = .secondaryLabelColor, bold: Bool = false) {
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color])
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        text("实体按键反馈", x: 0, y: 0, size: 13, color: .labelColor, bold: true)
        text(active ? "连接中 · 收到事件时闪亮" : "SPP 连接期间持续监听", x: 112, y: 2)
        let width = (bounds.width-20)/3
        for (index, kind) in MicButton.allCases.enumerated() {
            let x = CGFloat(index) * (width+10)
            let flashing = dates[kind].map { Date().timeIntervalSince($0) < 0.8 } ?? false
            let rect = NSRect(x: x, y: 26, width: width, height: 82)
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            (flashing ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.controlBackgroundColor).setFill(); path.fill()
            (flashing ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.5)).setStroke(); path.lineWidth = flashing ? 2 : 1; path.stroke()
            let title: String, subtitle: String
            switch kind {
            case .power: title = "电源键"; subtitle = "降噪相关状态 · 候选"
            case .record: title = "录音键"; subtitle = "本机录音相关状态 · 候选"
            case .link: title = "连接键"; subtitle = "短按候选 · 状态位上升沿"
            }
            text(title, x: x+12, y: 36, size: 13, color: .labelColor, bold: true)
            text("\(counts[kind, default: 0]) 次", x: x+width-52, y: 38, color: flashing ? .controlAccentColor : .secondaryLabelColor)
            text(subtitle, x: x+12, y: 59)
            let detail = dates[kind].map { formatter.string(from: $0) + "  " + (values[kind] ?? "") } ?? "尚未触发"
            text(detail, x: x+12, y: 82, size: 10)
        }
    }
}
