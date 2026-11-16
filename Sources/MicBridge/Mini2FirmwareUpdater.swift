import AppKit
import CoreBluetooth
import Combine
import Mini2Protocol

final class Mini2FirmwareLog {
    let url: URL
    init() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MicBridge/Firmware")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent(UUID().uuidString + ".jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    func add(_ text: String, fields: [String: Any] = [:]) {
        var fields = fields; fields["message"] = text; fields["time"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let file = try? FileHandle(forWritingTo: url) else { return }
        data.append(10); defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
    }
}

/// Deliberately separate from normal SPP. No arbitrary target, image, downgrade, or auto-retry.
final class Mini2FirmwareUpdater: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Stage { case select, preparing, checking, ready, flashing, rebooting, done, failed }
    @Published private(set) var stage = Stage.select
    @Published private(set) var status = "选择刷入类型与对应固件文件"
    @Published private(set) var fileName = "尚未选择固件"
    @Published private(set) var deviceInfo = ""
    @Published private(set) var kind = Mini2FirmwareImage.Kind.advanced
    @Published private(set) var fileReady = false
    let transfer: Mini2FirmwareTransfer
    let log: Mini2FirmwareLog
    private weak var bridge: BridgeController?
    private let address: String
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?, notifier: CBCharacteristic?, otaWriter: CBCharacteristic?, otaNotifier: CBCharacteristic?
    private var controlWriting = false
    private var queuedCommand: Mini2Command?
    private var request: Mini2Request?
    private var parser = Mini2DUMLParser()
    private var timer: Timer?
    private var deadline: TimeInterval = 0
    private var verifiedAt: TimeInterval = 0
    private var version = "", battery = 0
    private var readback = false
    private var closing = false
    private var finishClose: (() -> Void)?
    private let audio = Mini2FirmwareAudioGuard()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var blocksClose: Bool { [.preparing, .flashing, .rebooting].contains(stage) }
    var canCheck: Bool { fileReady && (stage == .select) && peripheral == nil }
    var canFlash: Bool { stage == .ready && !controlWriting && now - verifiedAt < 120 && battery >= 50 && otaWriter != nil && otaNotifier != nil }
    init(bridge: BridgeController, address: String) {
        self.bridge = bridge; self.address = address
        let log = Mini2FirmwareLog(); self.log = log; transfer = Mini2FirmwareTransfer(log: log)
        super.init()
        transfer.completed = { [weak self] ok in
            guard let self else { return }
            if ok {
                self.stage = .rebooting; self.readback = true; self.deadline = self.now + 90
                self.status = "设备校验通过，等待重启并回读版本…"
                // Stop control traffic until the target actually disconnects to reboot.
                self.request = nil
            } else { self.fail(self.transfer.status) }
        }
    }
    func chooseKind(_ kind: Mini2FirmwareImage.Kind) {
        guard stage == .select else { return }
        self.kind = kind; fileReady = false; fileName = "尚未选择固件"; status = "选择刷入类型与对应固件文件"
    }
    func chooseFile() {
        guard stage == .select else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = kind == .advanced ? "选择 Mini 2 MBRG r2 完整补丁包" : "选择 Mini 2 官方 02.03.17.00 完整原包"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let image = try Mini2FirmwareImage(package: Data(contentsOf: url), kind: kind)
            transfer.load(image); fileName = url.lastPathComponent; fileReady = true
            status = "文件与 TX 镜像 SHA-256 校验通过"
            log.add(status, fields: ["kind": kind.rawValue, "sha256": kind == .official ? Mini2StockImage.packageSHA256 : Mini2FirmwareImage.advancedSHA256])
        } catch { fileReady = false; status = error.localizedDescription }
    }
    func check() {
        guard canCheck else { return }
        stage = .preparing; status = "退出 SPP，准备独立 BLE 刷写连接…"
        bridge?.prepareFirmware(address: address) { [weak self] error in
            guard let self else { return }
            if let error { self.fail(error); return }
            do { try self.audio.lock(); guard try !self.audio.djiAudioActive() else { throw Mini2OTAError.invalid("请关闭使用 DJI 输入的录音与系统电平页面") } }
            catch { self.fail(error.localizedDescription); return }
            self.stage = .checking; self.deadline = self.now + 30; self.status = "寻找当前 Mini 2，读取型号、固件与电量…"
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
            self.central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }
    func flash() {
        guard canFlash, let p = peripheral, let otaNotifier else { return }
        do { try audio.enforce(); guard try !audio.djiAudioActive() else { throw Mini2OTAError.invalid("DJI 原生音频仍在使用；未开始刷写") } }
        catch { fail(error.localizedDescription); return }
        stage = .flashing; deadline = now + 10; status = "订阅固件传输通道…"
        p.setNotifyValue(true, for: otaNotifier)
    }
    func close(completion: @escaping () -> Void) {
        guard !blocksClose else { return }
        closing = true; finishClose = completion; central?.stopScan()
        if let peripheral, peripheral.state != .disconnected { central?.cancelPeripheralConnection(peripheral) }
        else { finishClosing() }
    }
    private func finishClosing() {
        timer?.invalidate(); timer = nil; central?.delegate = nil; central = nil
        peripheral?.delegate = nil; peripheral = nil
        let done = finishClose; finishClose = nil; done?()
    }
    private func fail(_ message: String) {
        stage = .failed; status = message; log.add(message); request = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }
    private func tick() {
        guard !closing else { return }
        if stage == .ready && !controlWriting && now - verifiedAt >= 120 { fail("设备检查已过期，请关闭弹窗后重新检查"); return }
        if [.checking, .rebooting].contains(stage) || (stage == .flashing && !transfer.active) {
            if now >= deadline { fail(readback ? "设备已通过镜像校验，但重启回读未确认。请勿自动重刷；检查设备并重新连接。" : "连接或检查超时，未开始固件传输"); return }
        }
    }
    private func clearEndpoints() { controlWriting = false; queuedCommand = nil; writer = nil; notifier = nil; otaWriter = nil; otaNotifier = nil; request = nil; parser = Mini2DUMLParser() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !closing else { return }
        if central.state == .poweredOn { scan() }
        else if [.unauthorized, .unsupported, .poweredOff].contains(central.state) { transfer.disconnected(); fail("蓝牙不可用或尚未获授权") }
    }
    private func scan() { central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closing, [.checking, .rebooting].contains(stage), peripheral == nil,
              Mini2FirmwareIdentity.matches(advertisedName: (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "", address: address, model: .mini2) else { return }
        central.stopScan(); peripheral = p; p.delegate = self; central.connect(p)
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral, !closing else { central.cancelPeripheralConnection(p); return }
        clearEndpoints(); p.discoverServices([CBUUID(string: "FFF0"), CBUUID(string: "E49A25F8-F69A-11E8-8EB2-F2801F1B9FD1")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }; peripheral = nil
        if closing { finishClosing() } else { fail("BLE 连接失败，未自动重试") }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        p.delegate = nil; peripheral = nil; clearEndpoints()
        if closing { finishClosing(); return }
        if stage == .rebooting { scan(); return }
        if stage == .done || stage == .failed { return }
        transfer.disconnected(); fail("BLE 连接断开；刷写结果未确认，不自动重刷")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral, !closing else { return }
        if let error { fail(error.localizedDescription); return }
        for service in p.services ?? [] { p.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral, !closing else { return }
        if let error { fail(error.localizedDescription); return }
        for c in service.characteristics ?? [] {
            if service.uuid == CBUUID(string: "FFF0") {
                if c.uuid == CBUUID(string: "FFF3"), c.properties.contains(.write) { writer = c }
                if c.uuid == CBUUID(string: "FFF4"), !c.properties.intersection([.notify, .indicate]).isEmpty { notifier = c }
            } else if service.uuid == CBUUID(string: "E49A25F8-F69A-11E8-8EB2-F2801F1B9FD1") {
                if c.uuid == CBUUID(string: "E49A25E0-F69A-11E8-8EB2-F2801F1B9FD1"), c.properties.contains(.write) { otaWriter = c }
                if c.uuid == CBUUID(string: "E49A28E1-F69A-11E8-8EB2-F2801F1B9FD1"), c.properties.contains(.notify) { otaNotifier = c }
            }
        }
        objectWillChange.send()
        if writer != nil, let notifier, !notifier.isNotifying { p.setNotifyValue(true, for: notifier) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, !closing else { return }
        guard error == nil, c.isNotifying else { fail("通知订阅失败"); return }
        if c === notifier, request == nil { send(.version) }
        if c === otaNotifier, stage == .flashing, let otaWriter {
            transfer.write = { [weak p, weak otaWriter] data in
                guard let p, let otaWriter else { return }; p.writeValue(data, for: otaWriter, type: .withResponse)
            }
            transfer.keepAudioIdle = { [weak self] in try self?.audio.enforce() }
            transfer.begin(maximumPacket: min(244, p.maximumWriteValueLength(for: .withResponse)))
        }
    }
    private func send(_ command: Mini2Command) {
        if controlWriting { queuedCommand = command; return }
        guard let p = peripheral, let writer else { fail("设备控制通道不可用"); return }
        let request = Mini2Request(command, sequence: UInt16.random(in: 1...65535))
        guard request.packet.count <= p.maximumWriteValueLength(for: .withResponse) else { fail("BLE 数据长度不足"); return }
        self.request = request; controlWriting = true
        p.writeValue(Data(request.packet), for: writer, type: .withResponse)
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, !closing else { return }
        if c === otaWriter { transfer.didWrite(error: error) }
        if c === writer {
            controlWriting = false
            if let next = queuedCommand { queuedCommand = nil; send(next) }
            objectWillChange.send()
        }
        // FFF3 can report ATT Unlikely Error while its DUML reply still arrives.
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, !closing else { return }
        if c === otaNotifier { if let error { fail(error.localizedDescription); transfer.disconnected() } else if let data = c.value { transfer.receive(data) }; return }
        guard c === notifier, error == nil, let data = c.value else { return }
        for frame in parser.feed(data) {
            guard let request, request.matches(frame) else { continue }
            do {
                let payload = try request.validate(frame); self.request = nil
                switch request.command {
                case .version:
                    version = Mini2Request.version(payload) ?? ""
                    guard Mini2Request.product(payload) == "DJI MIC MINI TX", version == "02.03.17.00" else { throw Mini2OTAError.invalid("型号或基准固件不符；仅支持 Mini 2 02.03.17.00") }
                    if readback {
                        stage = .done; status = "刷入完成 · 设备校验通过，重启后已回读 02.03.17.00"
                        deviceInfo = "Mini 2 · 02.03.17.00"
                        bridge?.firmwareFinished()
                        central?.cancelPeripheralConnection(p); log.add(status); return
                    }
                    send(.battery)
                case .battery:
                    battery = Int(payload[0]); let mv = Int(payload[1]) | Int(payload[2]) << 8
                    guard battery >= 50, mv > 0 else { throw Mini2OTAError.invalid("电量需至少 50%，请充电后重新检查") }
                    deviceInfo = "Mini 2 · \(version) · \(battery)%"; send(.keyExit)
                case .keyExit:
                    verifiedAt = now; stage = .ready; status = "设备检查通过，确认后开始刷入"
                default: break
                }
            } catch { fail(error.localizedDescription) }
        }
    }
}
