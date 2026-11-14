import AppKit
import CoreBluetooth
import Combine
import Mini2Protocol
import MicLinkCore

struct BLEDeviceRow: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}
struct BLECharacteristicRow: Identifiable {
    let id: String
    let label: String
    let value: CBCharacteristic
}

/// Main-queue CoreBluetooth delegate. Merely opening the window does not initialize Bluetooth.
final class BLEController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let ota: StockOTAController
    private var otaWrite: CBCharacteristic?
    private var otaNotify: CBCharacteristic?
    private var otaStarting = false
    private var otaStartDeadline: TimeInterval = 0
    private let otaAudio = Mini2AudioGuard()
    private var versionReadAt: TimeInterval = 0
    private var batteryReadAt: TimeInterval = 0
    private var batteryPercent: Int?
    var otaLocked: Bool { otaStarting || ota.active }
    @Published private(set) var devices: [BLEDeviceRow] = []
    @Published var selectedDevice: UUID?
    @Published private(set) var characteristics: [BLECharacteristicRow] = []
    @Published var writeID = ""
    @Published var notifyID = ""
    @Published private(set) var status = "等待实测 · 点击扫描后才访问蓝牙"
    @Published private(set) var connectedName = "未连接"
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var subscribed = false
    @Published private(set) var busy = false
    @Published private(set) var version = "—"
    @Published private(set) var battery = "—"
    @Published private(set) var key6 = 0
    @Published private(set) var key7 = 0
    @Published private(set) var lastKey: UInt8?
    @Published private(set) var keyState = "未进入"
    @Published private(set) var secondsLeft = 0
    @Published private(set) var verifiedModel = false
    @Published private(set) var exitVerified = false
    private(set) var keyMayBeActive = false
    private let log: DemoLog
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var scanRequested = false
    private var parser = Mini2DUMLParser()
    private var pending: Mini2Request?
    private var sequence: UInt16 = 1
    private var writeInFlight = false
    private var responseDeadline: TimeInterval = 0
    private var keyDeadline: TimeInterval?
    private var keyOwner: UUID?
    private var exitDeadline: TimeInterval?
    private var scanDeadline: TimeInterval = 0
    private var connectDeadline: TimeInterval = 0
    private var exitQueued = false
    private var afterExit: ((Bool) -> Void)?
    private var tickTimer: Timer?
    private var subscribedCharacteristic: CBCharacteristic?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var connected: Bool { peripheral?.state == .connected }
    var canQuery: Bool { connected && subscribed && !writeID.isEmpty && !busy && !writeInFlight && !exitQueued && !otaLocked }
    var canEnter: Bool { canQuery && verifiedModel && exitVerified && !keyMayBeActive }
    var canDisconnect: Bool { peripheral != nil }
    var canChangeEndpoints: Bool { connected && !busy && !writeInFlight && !keyMayBeActive && !subscribed && !otaLocked }

    init(log: DemoLog) {
        self.log = log; self.ota = StockOTAController(log: log); super.init()
        if let saved = UserDefaults.standard.string(forKey: "unfinishedMini2KeyTrial"), let id = UUID(uuidString: saved) {
            keyOwner = id; keyMayBeActive = true
            keyState = "上次测试退出未确认 · 请连接原设备确认退出"
        }
    }
    func scan() {
        guard peripheral == nil else { return }
        devices = []; peripherals = [:]; selectedDevice = nil
        scanRequested = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else { startScanIfReady() }
        if tickTimer == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common); tickTimer = timer
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.add("蓝牙状态：\(central.state.rawValue)")
        if central.state == .poweredOn { startScanIfReady() }
        else {
            scanning = false
            status = central.state == .unauthorized ? "请允许 Mini 2 Demo 使用蓝牙，再点击扫描" : "蓝牙尚未就绪"
        }
    }
    private func startScanIfReady() {
        guard scanRequested, central?.state == .poweredOn else { return }
        scanRequested = false; scanning = true; scanDeadline = now + 15
        status = "扫描 BLE 广播（15 秒），请选择 Mini 2"
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log.add("开始 BLE 扫描；不自动连接")
    }
    func stopScan() { central?.stopScan(); scanning = false; scanRequested = false }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "未命名设备"
        let isNew = peripherals[p.identifier] == nil
        peripherals[p.identifier] = p
        let row = BLEDeviceRow(id: p.identifier, name: name, rssi: RSSI.intValue)
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) { devices[i] = row } else { devices.append(row) }
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if isNew { log.add("发现 BLE：\(name)", fields: ["peripheral": p.identifier.uuidString, "rssi": RSSI.intValue]) }
    }
    func connect() {
        guard peripheral == nil, let id = selectedDevice, let p = peripherals[id] else { return }
        guard !keyMayBeActive || keyOwner == id else {
            report("请先连接上次按键测试的原设备并确认退出，不能用另一台设备的 ACK 清除状态")
            return
        }
        stopScan(); peripheral = p; p.delegate = self
        resetConnection(); connecting = true; connectDeadline = now + 15
        connectedName = p.name ?? "BLE 设备"; status = "连接 BLE…"
        central?.connect(p); log.add("请求 BLE 连接：\(connectedName)")
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { central.cancelPeripheralConnection(p); return }
        connecting = false; status = "读取服务列表…"; p.discoverServices(nil)
        log.add("BLE 已连接，开始发现服务")
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        lostConnection(error?.localizedDescription ?? "连接失败")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        lostConnection(error?.localizedDescription ?? "BLE 已断开")
    }
    private func resetConnection() {
        otaWrite = nil; otaNotify = nil; otaStarting = false
        versionReadAt = 0; batteryReadAt = 0; batteryPercent = nil
        characteristics = []; writeID = ""; notifyID = ""; subscribed = false
        subscribedCharacteristic = nil; pending = nil; busy = false; writeInFlight = false
        parser = Mini2DUMLParser(); version = "—"; battery = "—"; verifiedModel = false; exitVerified = false
    }
    private func lostConnection(_ message: String) {
        ota.disconnected()
        if keyMayBeActive { keyState = "连接中断 · 按键模式状态未知" }
        keyDeadline = nil; exitDeadline = nil; secondsLeft = 0; exitQueued = false
        peripheral = nil; connecting = false; connectedName = "未连接"; resetConnection()
        status = message; log.add(message)
        let completion = afterExit; afterExit = nil; completion?(false)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        if let error { report(error.localizedDescription); return }
        for service in p.services ?? [] {
            log.add("BLE 服务：\(service.uuid.uuidString)"); p.discoverCharacteristics(nil, for: service)
        }
        status = "服务已发现，选择写入和通知特征后订阅"
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral else { return }
        if let error { report(error.localizedDescription); return }
        for (index, c) in (service.characteristics ?? []).enumerated() {
            let id = "\(service.uuid)/\(c.uuid)/\(index)"
            let label = "\(service.uuid) / \(c.uuid) · \(c.properties.rawValue)"
            characteristics.append(.init(id: id, label: label, value: c))
            log.add("BLE 特征：\(label)")
            if service.uuid == CBUUID(string: "E49A25F8-F69A-11E8-8EB2-F2801F1B9FD1") {
                if c.uuid == CBUUID(string: "E49A25E0-F69A-11E8-8EB2-F2801F1B9FD1"), c.properties.contains(.write) { otaWrite = c }
                if c.uuid == CBUUID(string: "E49A28E1-F69A-11E8-8EB2-F2801F1B9FD1"), c.properties.contains(.notify) { otaNotify = c }
            }
            if service.uuid == CBUUID(string: "FFF0"), c.uuid == CBUUID(string: "FFF3"), writeID.isEmpty,
               !c.properties.intersection([.write, .writeWithoutResponse]).isEmpty { writeID = id }
            if service.uuid == CBUUID(string: "FFF0"), c.uuid == CBUUID(string: "FFF4"), notifyID.isEmpty,
               !c.properties.intersection([.notify, .indicate]).isEmpty { notifyID = id }
        }
    }
    func subscribe() {
        guard canChangeEndpoints, let c = characteristics.first(where: { $0.id == notifyID })?.value,
              !c.properties.intersection([.notify, .indicate]).isEmpty else { return }
        subscribedCharacteristic = c; peripheral?.setNotifyValue(true, for: c)
        status = "订阅通知…"
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if p === peripheral, c === otaNotify {
            guard otaStarting else { return }
            otaStarting = false
            guard error == nil, c.isNotifying, let writer = otaWrite else { report("OTA 通知订阅失败"); return }
            ota.write = { [weak p, weak writer] data in
                guard let p, let writer else { return }
                p.writeValue(data, for: writer, type: .withResponse)
            }
            ota.keepAudioIdle = { [weak self] in try self?.otaAudio.enforce() }
            ota.begin(maximumPacket: min(244, p.maximumWriteValueLength(for: .withResponse)))
            return
        }
        guard p === peripheral, c === subscribedCharacteristic else { return }
        subscribed = error == nil && c.isNotifying
        status = subscribed ? "控制通道就绪 · 先查询版本与电量" : "订阅失败：\(error?.localizedDescription ?? "通知未开启")"
        log.add(status)
    }
    func query(_ command: Mini2Command) {
        guard command != .keyEnter || canEnter else { return }
        guard canQuery else { return }
        send(command)
    }
    private func send(_ command: Mini2Command) {
        guard let p = peripheral, p.state == .connected, subscribed, !writeInFlight, pending == nil,
              let c = characteristics.first(where: { $0.id == writeID })?.value else {
            report("控制通道未就绪"); completeExit(false); return
        }
        let type: CBCharacteristicWriteType
        if c.properties.contains(.write) { type = .withResponse }
        else if c.properties.contains(.writeWithoutResponse), p.canSendWriteWithoutResponse { type = .withoutResponse }
        else { report("所选特征暂不可写入"); completeExit(false); return }
        sequence &+= 1
        let request = Mini2Request(command, sequence: sequence)
        guard request.packet.count <= p.maximumWriteValueLength(for: type) else {
            report("写入 MTU 小于请求长度，本次未发送"); completeExit(false); return
        }
        if command == .keyEnter {
            keyMayBeActive = true; keyState = "正在进入，等待 ACK"; keyDeadline = now + 60; exitVerified = false
            keyOwner = p.identifier
            UserDefaults.standard.set(p.identifier.uuidString, forKey: "unfinishedMini2KeyTrial")
        }
        pending = request; busy = true; responseDeadline = now + 5; writeInFlight = type == .withResponse
        log.add("BLE TX \(command.rawValue) seq=\(sequence)", fields: ["hex": request.packet.hex, "characteristic": c.uuid.uuidString])
        p.writeValue(Data(request.packet), for: c, type: type)
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if c === otaWrite { ota.didWrite(error: error); return }
        writeInFlight = false
        busy = pending != nil
        if let error {
            // Mini 2 02.03.17.00 can return ATT "Unlikely error" while sending
            // a valid DUML reply on FFF4. Retain the request until its matching
            // protocol ACK or deadline; neither ATT success nor failure is a DUML ACK.
            log.add("ATT 写入返回：\(error.localizedDescription)；继续等待匹配 DUML 回应")
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if p === peripheral, c === otaNotify {
            if let error { log.add("OTA 通知错误：\(error.localizedDescription)") }
            else if let data = c.value { ota.receive(data) }
            return
        }
        guard p === peripheral, c === subscribedCharacteristic else { return }
        if let error { report(error.localizedDescription); return }
        guard let data = c.value else { return }
        log.add("BLE RX \(data.count) 字节", fields: ["hex": data.hex, "characteristic": c.uuid.uuidString])
        for frame in parser.feed(data) {
            if observeKey(frame, transport: "BLE") { continue }
            guard let request = pending, request.matches(frame) else {
                log.add("其他 DUML 帧", fields: ["hex": frame.bytes.hex]); continue
            }
            pending = nil; busy = false
            do {
                let payload = try request.validate(frame)
                switch request.command {
                case .version:
                    versionReadAt = now
                    version = Mini2Request.version(payload) ?? "格式未知"
                    let product = Mini2Request.product(payload)
                    verifiedModel = version == "02.03.17.00" && product == "DJI MIC MINI TX"
                    status = "\(product) · \(version)"
                case .battery:
                    let mv = Int(payload[1]) | Int(payload[2]) << 8
                    battery = mv > 0 ? "\(payload[0])% · \(mv) mV" : "数据未就绪"
                    batteryPercent = mv > 0 ? Int(payload[0]) : nil; batteryReadAt = now
                    status = "电量查询：\(battery)"
                case .keyEnter:
                    keyState = "已收到进入 ACK · 等待独立按键报告"; status = keyState
                case .keyExit:
                    keyMayBeActive = false; exitVerified = true; keyDeadline = nil; secondsLeft = 0
                    keyOwner = nil; UserDefaults.standard.removeObject(forKey: "unfinishedMini2KeyTrial")
                    keyState = "已确认退出"; status = keyState; completeExit(true)
                }
                log.add("\(request.command.rawValue) 回应有效：\(status)")
            } catch {
                report(error.localizedDescription)
                if request.command == .keyExit { completeExit(false) }
            }
        }
    }
    func requestExit(completion: ((Bool) -> Void)? = nil) {
        guard !otaLocked else { completion?(false); return }
        if exitQueued || pending?.command == .keyExit || afterExit != nil {
            if let completion {
                let previous = afterExit
                afterExit = { ok in previous?(ok); completion(ok) }
            }
            return
        }
        afterExit = completion; exitQueued = true; keyDeadline = nil; secondsLeft = 0
        exitDeadline = now + 12
        status = "准备发送退出按键测试…"
    }
    private func completeExit(_ ok: Bool) {
        exitQueued = false; exitDeadline = nil
        let completion = afterExit; afterExit = nil; completion?(ok)
    }
    func disconnect() {
        guard !otaLocked else { return }
        guard let p = peripheral else { return }
        if keyMayBeActive {
            requestExit { [weak self, weak p] ok in
                if ok, let p { self?.central?.cancelPeripheralConnection(p) }
            }
        } else { central?.cancelPeripheralConnection(p) }
    }
    func prepareClose(_ completion: @escaping (Bool) -> Void) {
        guard !otaLocked else { report("官方固件传输中，请等待完成"); completion(false); return }
        stopScan()
        if keyMayBeActive {
            guard connected && subscribed else { report("按键模式状态未知，请连接原设备并确认退出测试"); completion(false); return }
            requestExit { [weak self] ok in
                if ok { self?.disconnect() }; completion(ok)
            }
        } else { disconnect(); completion(true) }
    }
    private func tick() {
        if otaStarting, now >= otaStartDeadline { otaStarting = false; report("OTA 订阅超时，未发送升级请求") }
        if scanning && now >= scanDeadline { stopScan(); status = "扫描结束 · 请选择设备" }
        if connecting && now >= connectDeadline, let p = peripheral {
            connecting = false; central?.cancelPeripheralConnection(p); report("BLE 连接超时")
        }
        if let request = pending, now >= responseDeadline {
            pending = nil; busy = false
            report("\(request.command.rawValue) 回应超时（未视为成功）")
            if request.command == .keyExit { completeExit(false) }
        }
        if let deadline = keyDeadline {
            secondsLeft = max(0, Int(ceil(deadline - now)))
            if now >= deadline { requestExit() }
        }
        if let deadline = exitDeadline, now >= deadline {
            report("退出测试未获确认；连接保留，可重试")
            completeExit(false)
        }
        if exitQueued, pending == nil, !writeInFlight {
            exitQueued = false; send(.keyExit)
        }
    }
    @discardableResult func observeKey(_ frame: Mini2Frame, transport: String) -> Bool {
        guard let key = frame.independentKey else { return false }
        if key == 6 { key6 += 1 } else { key7 += 1 }; lastKey = key
        log.add("\(transport) 独立按键报告 KEY \(key)（不是模式 ACK）", fields: ["hex": frame.bytes.hex])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.lastKey = nil }
        return true
    }
    private func report(_ text: String) { status = text; log.add(text) }

    func startStockOTA(sppActive: Bool) {
        guard canQuery, ota.prepared, verifiedModel, now - versionReadAt < 120,
              now - batteryReadAt < 120, (batteryPercent ?? 0) >= 50,
              !keyMayBeActive, exitVerified, !sppActive,
              let p = peripheral, let notify = otaNotify, otaWrite != nil else {
            report("平刷前请回读 02.03.17.00 和电量（至少 50%）、确认退出按键测试并关闭 SPP")
            return
        }
        do {
            try otaAudio.lock()
            guard try !otaAudio.djiAudioActive() else { report("DJI 音频仍在使用，请关闭系统电平/录音后重试"); return }
        } catch { report(error.localizedDescription); return }
        otaStarting = true; otaStartDeadline = now + 10
        status = "订阅专用 OTA 通知…"; p.setNotifyValue(true, for: notify)
    }
}
