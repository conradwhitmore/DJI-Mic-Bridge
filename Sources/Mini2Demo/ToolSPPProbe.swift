import Foundation
import IOBluetooth
import Mini2Protocol

/// One bounded handshake on the separately discovered e004 service. No audio routing or gain writes.
final class ToolSPPProbe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var update: ((String) -> Void)?
    private let device: IOBluetoothDevice
    private let channelID: BluetoothRFCOMMChannelID
    private let log: DemoLog
    private var channel: IOBluetoothRFCOMMChannel?
    private var timer: Timer?
    private var stopping = false
    private var sent = false
    private var rx: [UInt8] = []
    private let sequence: UInt8 = 0x5a
    private let versionOnly: Bool
    private(set) var active = false
    private var completion: ((Bool) -> Void)?
    init(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID, log: DemoLog, versionOnly: Bool = false) {
        self.device = device; self.channelID = channelID; self.log = log; self.versionOnly = versionOnly
    }
    private func report(_ text: String) { log.add(text); update?(text) }
    private func deadline(_ seconds: TimeInterval, action: @escaping () -> Void) {
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in action() }
    }
    func start() {
        guard !active else { return }; active = true
        report("e004 请求打开 RFCOMM \(channelID)，" + (versionOnly ? "只读版本查询" : "仅握手"))
        deadline(12) { [weak self] in self?.report("e004 打开或握手超时"); self?.stop() }
        let rc = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        if rc != 0 { report("e004 打开失败：\(rc)"); stop() }
    }
    func rfcommChannelOpenComplete(_ opened: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.rfcommChannelOpenComplete(opened, status: status) }; return }
        guard let opened, opened.getDevice()?.addressString == device.addressString,
              opened.getID() == channelID else { return }
        channel = opened
        guard !stopping else {
            if status != 0 {
                timer?.invalidate(); active = false
                report("e004 迟到的打开失败回调：\(status)，请求已结束")
                completion?(true); completion = nil
            } else { _ = opened.close() }
            return
        }
        guard status == 0 else { report("e004 通道打开回调失败：\(status)"); stop(); return }
        report("e004 已打开，等待 500 毫秒让工具线程就绪")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sendProbe() }
    }
    private func sendProbe() {
        guard let channel, !stopping, !sent else { return }; sent = true
        var bytes: [UInt8] = versionOnly ? [0x41, 0, 0, 0, 0, 0, 0] : Mini2ToolHandshake.request(sequence: sequence)
        log.add(versionOnly ? "e004 发送只读版本查询" : "e004 发送 ABTP 握手", fields: ["hex": bytes.map { String(format: "%02X", $0) }.joined(separator: " ")])
        let count = bytes.count
        let rc = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16(count)) }
        log.add("e004 写入结果", fields: ["result": Int(rc), "count": count])
        if rc != 0 { report("e004 写入失败：\(rc)"); stop() }
    }

    func rfcommChannelData(_ source: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard let pointer, count > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count))
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopping, self.sent, source?.getObjectID() == self.channel?.getObjectID() else { return }
            self.log.add("e004 接收", fields: ["hex": bytes.map { String(format: "%02X", $0) }.joined(separator: " ")])
            guard self.rx.count + bytes.count <= 512 else { self.report("e004 非预期数据，结束握手测试"); self.stop(); return }
            self.rx += bytes
            if self.versionOnly {
                let text = String(decoding: self.rx, as: UTF8.self)
                if text.contains("User_Ver") || text.contains("Case_Type") {
                    self.report("e004 收到版本文本：" + text)
                    self.deadline(2) { [weak self] in self?.stop() }
                }
                return
            }
            if self.rx.count >= 4 {
                guard Mini2ToolHandshake.acknowledged(self.rx, sequence: self.sequence) else {
                    self.report("e004 回应与握手不匹配"); self.stop(); return
                }
                self.report("e004 握手成功 ACK 00；保持 30 秒观察收音并存")
                self.deadline(30) { [weak self] in self?.stop() }
            }
        }
    }
    func stop(completion: ((Bool) -> Void)? = nil) {
        if !active { completion?(true); return }
        if let completion { self.completion = completion }
        if stopping { return }; stopping = true; timer?.invalidate()
        guard let channel else { active = false; self.completion?(true); self.completion = nil; return }
        let rc = channel.close(); report("e004 请求关闭调试通道：\(rc)")
        if !active { return }
        deadline(8) { [weak self] in
            guard let self, self.active else { return }
            self.report("e004 未收到关闭通知，请保留 Demo")
            self.completion?(false); self.completion = nil
        }
    }
    func rfcommChannelClosed(_ closed: IOBluetoothRFCOMMChannel!) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.rfcommChannelClosed(closed) }; return }
        guard closed?.getObjectID() == channel?.getObjectID() else { return }
        timer?.invalidate(); active = false; stopping = true
        report("e004 调试通道已关闭；未发送增益或校准指令")
        completion?(true); completion = nil
    }
}
