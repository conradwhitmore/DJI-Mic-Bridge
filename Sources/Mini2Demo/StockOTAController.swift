import Foundation
import Combine
import Mini2Protocol

/// Main queue. One ATT write at a time; no speculative writes or host-initiated retries.
final class StockOTAController: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var status = "未加载官方原包"
    @Published private(set) var progress = 0.0
    @Published private(set) var prepared = false
    private(set) var image: Mini2StockImage?
    private var host: Mini2OTAHost?
    private var parser = OTAParser()
    private var queue: [(OTAFrame, Range<Int>?)] = []
    private var inFlight: (OTAFrame, Range<Int>?)?
    private var coverage: [Bool] = []
    private var covered = 0
    private var acknowledged = 0
    private var timer: Timer?
    private var lastActivity: TimeInterval = 0
    private var activity: NSObjectProtocol?
    private let log: DemoLog
    var write: ((Data) -> Void)?
    var keepAudioIdle: (() throws -> Void)?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    init(log: DemoLog) { self.log = log }
    func load(_ url: URL) {
        guard !active else { return }
        do {
            let data = try Data(contentsOf: url)
            image = try Mini2StockImage(package: data); prepared = true
            status = "官方 02.03.17.00 · TX 724,992 字节 · 原包 SHA-256 已核对"
            log.add(status, fields: ["package_sha256": Mini2StockImage.packageSHA256, "tx_sha256": Mini2StockImage.txSHA256])
        } catch { image = nil; prepared = false; status = error.localizedDescription; log.add(status) }
    }
    func begin(maximumPacket: Int) {
        guard !active, let image, write != nil else { return }
        do {
            try keepAudioIdle?()
            host = Mini2OTAHost(image: image.bytes, maximumPacket: maximumPacket)
            let first = try host!.start()
            parser = OTAParser(); queue = []; inFlight = nil
            coverage = Array(repeating: false, count: image.bytes.count); covered = 0; acknowledged = 0; progress = 0
            active = true; lastActivity = now
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Mini 2 official firmware transfer")
            status = "请求官方固件平刷…"
            log.add(status, fields: ["maximum_att_write": maximumPacket])
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            queue = [(first, nil)]; pump()
        } catch { fail(error.localizedDescription) }
    }
    func receive(_ data: Data) {
        guard active else { return }
        lastActivity = now
        log.add("OTA RX", fields: ["hex": data.map { String(format: "%02x", $0) }.joined()])
        do {
            for frame in try parser.feed(data) {
                guard host != nil else { return }
                let replies = try host!.receive(frame)
                if frame.command == 3 {
                    let fields = try frame.fields()
                    var offset = Int(try OTAFrame.value(fields, 1, size: 4))
                    let length = Int(try OTAFrame.value(fields, 2, size: 4))
                    log.add("OTA 请求镜像数据", fields: ["offset": offset, "length": length, "packets": replies.count])
                    // Target retries a whole range with PSN reset. Retire any unsent old range,
                    // and let the already submitted single ATT write finish first.
                    queue.removeAll()
                    for packet in replies {
                        let n = packet.payload.count - 5
                        queue.append((packet, offset..<offset+n)); offset += n
                    }
                    status = "传输官方 TX 镜像…"
                } else {
                    queue += replies.map { ($0, nil) }
                    if host?.phase == .negotiation { status = "设备已接受 OTA，协商传输参数…" }
                    if host?.phase == .transfer, frame.command == 2 {
                        status = "协商完成，等待设备请求数据…"
                        log.add(status, fields: ["payload_bytes": host!.unitSize])
                    }
                    if frame.command == 6 {
                        status = host?.phase == .validated ? "设备报告镜像校验通过，发送完成确认…" : "设备报告镜像校验失败"
                        log.add(status, fields: ["covered_bytes": covered, "acknowledged_payload_bytes": acknowledged])
                    }
                }
            }
            pump()
        } catch { fail(error.localizedDescription) }
    }
    func didWrite(error: Error?) {
        guard active, let current = inFlight else { return }
        inFlight = nil; lastActivity = now
        if let error { fail("OTA ATT 写入失败：\(error.localizedDescription)"); return }
        if let range = current.1 { acknowledged += range.count }
        if current.0.command == 6 {
            let valid = host?.phase == .validated
            finish()
            status = valid ? "设备镜像校验通过 · 等待设备重启并回读版本" : "设备校验失败 · 未完成平刷"
            log.add(status, fields: ["covered_bytes": covered, "total_bytes": coverage.count])
            return
        }
        pump()
    }
    private func pump() {
        guard active, inFlight == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst(); inFlight = item
        if let range = item.1 {
            for i in range where !coverage[i] { coverage[i] = true; covered += 1 }
            progress = Double(covered) / Double(coverage.count)
        } else {
            log.add("OTA TX 控制", fields: ["hex": item.0.data.map { String(format: "%02x", $0) }.joined()])
        }
        write?(item.0.data)
    }
    func disconnected() {
        if active { fail("BLE 在完成确认前断开；结果未确认，不自动重刷") }
    }
    private func tick() {
        guard active else { return }
        do { try keepAudioIdle?() } catch { log.add("OTA 音频路由检查：\(error.localizedDescription)") }
        if now - lastActivity > 60 { fail("OTA 连续 60 秒无进展；已停止发送，保留日志，不自动重刷") }
    }
    private func fail(_ text: String) { finish(); status = text; log.add(text) }
    private func finish() {
        active = false; queue.removeAll(); inFlight = nil; timer?.invalidate(); timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
}
