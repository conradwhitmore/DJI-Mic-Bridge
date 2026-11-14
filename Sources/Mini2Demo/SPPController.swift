import AppKit
import IOBluetooth
import Combine
import Mini2Protocol
import MicLinkCore

struct ClassicDeviceRow: Identifiable {
    let id: String
    let name: String
    let device: IOBluetoothDevice
}

final class SPPController: NSObject, ObservableObject {
    var hotkey: ((Mini2Hotkey) -> Void)?
    var controlFrame: ((Mini2Frame) -> Void)?
    @Published private(set) var devices: [ClassicDeviceRow] = []
    @Published var selected = ""
    @Published private(set) var status = "未连接"
    @Published private(set) var commandStatus = "未验证 SPP 指令"
    @Published private(set) var probing = false
    @Published private(set) var denoise: Bool?
    @Published private(set) var canSetDenoise = false
    @Published private(set) var denoiseBusy = false
    @Published private(set) var denoiseResult = "等待新鲜状态帧"
    @Published private(set) var denoiseButton = "—"
    @Published private(set) var captureCount = 0
    @Published private(set) var statusMetrics = "等待普通 SPP 状态包"
    @Published private(set) var channelID: BluetoothRFCOMMChannelID = 0
    @Published private(set) var discovering = false
    @Published private(set) var active = false
    @Published private(set) var opened = false
    @Published private(set) var recording = false
    @Published private(set) var metrics = "0 字节 · 0 个封装 · 0 个无线子块"
    private let log: DemoLog
    private var queryDevice: IOBluetoothDevice?
    private var discoveredDevice: String?
    private var probe: SPPProbe?
    private var retired: [SPPProbe] = []
    private var discoveryTimer: Timer?
    private let deviceQueue = DispatchQueue(label: "org.micbridge.mini2-demo.paired-devices")
    init(log: DemoLog) { self.log = log; super.init() }
    func refresh() {
        guard !active, !discovering else { return }
        channelID = 0; discoveredDevice = nil; selected = ""
        discovering = true
        status = "读取已配对设备…"
        // IOBluetooth initializes its CoreBluetooth coordinator synchronously.
        // Leave the main run loop available for that initialization and authorization.
        deviceQueue.async { [weak self] in
            let rows: [ClassicDeviceRow] = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).compactMap { device in
                guard let name = device.name, name.uppercased().contains("MINI"), let address = device.addressString else { return nil }
                return .init(id: address, name: "\(name) · \(device.isConnected() ? "蓝牙已连接" : "未连接")", device: device)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.devices = rows
                self.discovering = false
                self.status = "已读取 \(rows.count) 台已配对 Mini；请明确选择设备"
            }
        }
    }
    func discover() {
        guard !active, !discovering, let row = devices.first(where: { $0.id == selected }) else { return }
        guard row.device.isConnected() else { status = "请先将所选 Mini 2 连接到 Mac"; return }
        channelID = 0; discoveredDevice = nil; discovering = true; queryDevice = row.device
        log.add("请求 Mini 的 SDP 服务列表", fields: ["device": row.id])
        let rc = row.device.performSDPQuery(self)
        if rc != 0 { discovering = false; status = "SDP 请求失败：\(rc)"; return }
        status = "查询 SDP…"
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self, self.discovering else { return }
            self.status = "SDP 查询尚未返回；可稍后刷新重试"; self.discovering = false; self.queryDevice = nil
        }
    }
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status result: IOReturn) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.sdpQueryComplete(device, status: result) }; return }
        guard let device, device === queryDevice, discovering else { return }
        discovering = false; queryDevice = nil; discoveryTimer?.invalidate()
        guard result == 0, let service = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1101)) else {
            status = "没有发现 Serial Port 1101 服务（\(result)）"; log.add(status); return
        }
        var channel: BluetoothRFCOMMChannelID = 0
        let rc = service.getRFCOMMChannelID(&channel)
        guard rc == 0, (1...30).contains(channel) else { status = "SDP 未返回有效 RFCOMM 通道"; return }
        channelID = channel; discoveredDevice = device.addressString
        status = "发现 SPP · RFCOMM \(channel)"; log.add(status)
    }
    var canOpen: Bool { !active && !discovering && channelID > 0 && selected == discoveredDevice }
    func open() {
        guard canOpen, let row = devices.first(where: { $0.id == selected }), row.device.isConnected() else { return }
        active = true
        let new = SPPProbe(device: row.device, channelID: channelID, log: log)
        if let probe { retired.append(probe) }
        probe = new
        new.hotkey = { [weak self, weak new] key in
            guard let self, self.probe === new else { return }; self.hotkey?(key)
        }
        captureCount = 0; statusMetrics = "等待普通 SPP 状态包"
        new.denoiseUpdate = { [weak self, weak new] value, ready, busy, result, button in
            guard let self, self.probe === new else { return }
            self.denoise = value; self.canSetDenoise = ready; self.denoiseBusy = busy
            self.denoiseResult = result; self.denoiseButton = button
        }
        new.statusUpdate = { [weak self, weak new] count, text in
            guard let self, self.probe === new else { return }
            self.captureCount = count; self.statusMetrics = text
        }
        new.commandUpdate = { [weak self, weak new] text, busy in
            guard let self, self.probe === new else { return }
            self.commandStatus = text; self.probing = busy
        }
        new.controlFrame = { [weak self, weak new] frame in
            guard let self, self.probe === new else { return }; self.controlFrame?(frame)
        }
        new.update = { [weak self, weak new] text, opened, recording, metrics in
            guard let self, self.probe === new else { return }
            self.status = text; self.opened = opened; self.recording = recording; self.metrics = metrics
        }
        new.finished = { [weak self, weak new] confirmed in
            guard let self, self.probe === new else { return }
            self.opened = false; self.recording = false
            // Keep the delegate alive even after close; late open callbacks still get cancelled.
            if confirmed { self.active = false }
        }
        new.start()
    }
    func close(completion: ((Bool) -> Void)? = nil) {
        guard let probe else { completion?(true); return }
        probe.stop(completion: completion)
    }
    func toggleCapture() { probe?.toggleCapture() }
    func verifyCommands() { probe?.verifyCommands() }
    func exitSPP() { probe?.exitSPP() }
    func setDenoise(_ enabled: Bool) { probe?.setDenoise(enabled) }
}

private final class SPPProbe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var hotkey: ((Mini2Hotkey) -> Void)?
    private var hotkeyDetector = Mini2SPPHotkeys()
    var statusUpdate: ((Int, String) -> Void)?
    private var statusParser = Mini2StatusParser()
    private var statusFrames = 0, captureEvents = 0
    private var lastStatus: [UInt8]?
    var denoiseUpdate: ((Bool?, Bool, Bool, String, String) -> Void)?
    private var currentStatus: Mini2SPPStatus?
    private var lastStatusTime: TimeInterval = 0
    private var pendingDenoise: Mini2DenoiseConfirmation?
    private var denoiseResult = "等待新鲜状态帧"
    var controlFrame: ((Mini2Frame) -> Void)?
    let device: IOBluetoothDevice
    let channelID: BluetoothRFCOMMChannelID
    let log: DemoLog
    var update: ((String, Bool, Bool, String) -> Void)?
    var finished: ((Bool) -> Void)?
    var commandUpdate: ((String, Bool) -> Void)?
    private var commandQueue: [Mini2SPPCommand] = []
    private var pendingCommand: (Mini2SPPCommand, UInt16, TimeInterval)?
    private var pendingExit: (MicControlQuery, TimeInterval)?
    private var exitAcknowledged = false
    private var commandSequence: UInt16 = 0x200
    private var commandResults: [String] = []
    private var clockArmed = false
    private var routes = Mini2AudioGuard()
    private var channels: [UInt64: IOBluetoothRFCOMMChannel] = [:]
    private var closedIDs: Set<UInt64> = []
    private var notices: [IOBluetoothUserNotification] = []
    private var timer: Timer?
    private var parser = Mini2SPPParser()
    private var bytes = 0, envelopes = 0, blocks = 0
    private var started = ProcessInfo.processInfo.systemUptime
    private var requested = false, opened = false, stopping = false, completed = false
    private var outcome: RFCOMMCloseCoordinator.Outcome?
    private var message = "准备非 DJI 音频路由…"
    private var closeCompletion: ((Bool) -> Void)?
    private var raw: FileHandle?
    private var wav: WAVWriter?
    private var decoder: LC3Decoder?
    private var decodedFrames = 0, decodeErrors = 0, unknownBlocks = 0, sequenceGaps = 0
    private var lastAudioSequence: UInt8?
    private var rawDeadline: TimeInterval = 0
    private var lastRouteError = ""
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private lazy var closer = RFCOMMCloseCoordinator(timeout: 8, requestClose: { [weak self] id in
        guard let channel = self?.channels[id] else { return -1 }
        return channel.close()
    }, onOutcome: { [weak self] result in self?.closed(result) })
    init(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID, log: DemoLog) {
        self.device = device; self.channelID = channelID; self.log = log
    }
    func start() {
        started = now
        do { try routes.lock() } catch { message = error.localizedDescription; log.add(message); stop(); return }
        log.add("SPP 路由锁定：\(routes.summary)")
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common); publish()
    }
    private func tick() {
        if stopping {
            // A close request is not a close confirmation. Keep the non-DJI routes
            // protected while awaiting closure, including after a close timeout.
            do { try routes.enforce() } catch {
                let text = error.localizedDescription
                if lastRouteError != text { log.add(text); lastRouteError = text }
            }
            closer.tick(now: now); return
        }
        do {
            try routes.enforce()
            if try routes.djiAudioActive() {
                message = "检测到 DJI 系统音频占用；请关闭其他 App 的 DJI 输入"
                if lastRouteError != message { log.add(message); lastRouteError = message }
                // During capture preserve the diagnostic connection; no sequence-gap disconnect policy.
                if !requested { publish(); if now - started > 15 { stop() }; return }
            }
        } catch { message = error.localizedDescription; log.add(message); stop(); return }
        if !device.isConnected() { message = "设备蓝牙已断开"; stop(); return }
        if !requested && now - started >= 2 {
            requested = true; closer.openingStarted()
            var channel: IOBluetoothRFCOMMChannel?
            let rc = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
            if let channel { track(channel) }
            log.add("请求打开 SPP channel=\(channelID)，返回 \(rc)")
            if rc != 0 { closer.openingRequestFailed(); message = "SPP 打开请求失败：\(rc)"; stop() }
        }
        if requested && !opened && now - started > 15 { message = "SPP 打开超时"; stop() }
        if raw != nil && now >= rawDeadline { stopCapture() }
        if let (_, deadline) = pendingExit, now >= deadline {
            pendingExit = nil
            commandResults = ["12/65 未收到匹配 ACK；未自动重发，通道保留"]
            log.add(commandResults[0]); commandUpdate?(commandResults[0], false)
        }
        if let (command, _, deadline) = pendingCommand, now >= deadline {
            commandResults.append("\(command.rawValue)：未收到匹配回应")
            log.add(commandResults.last!); pendingCommand = nil; sendNextCommand()
        }
        if let pendingDenoise, pendingDenoise.expired(at: now) {
            self.pendingDenoise = nil; denoiseResult = "降噪指令超时：未确认目标状态"
            log.add(denoiseResult)
        }
        publish()
    }
    private func track(_ channel: IOBluetoothRFCOMMChannel) {
        let id = UInt64(channel.getObjectID())
        if channels[id] == nil {
            channels[id] = channel
            if let n = channel.register(forChannelCloseNotification: self, selector: #selector(closeNotice(_:channel:))) { notices.append(n) }
        }
        closer.channelAvailable(id: id)
    }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status rc: IOReturn) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.rfcommChannelOpenComplete(channel, status: rc) }; return }
        if let channel { track(channel) }
        closer.openingCompleted(id: channel.map { UInt64($0.getObjectID()) }, success: rc == 0)
        guard !stopping else { return }
        if rc != 0 { message = "SPP 打开失败：\(rc)"; stop(); return }
        opened = true; message = "SPP 已连接 · 可验证指令、保存原始流与 WAV"
        log.add(message, fields: ["mtu": channel?.getMTU() ?? 0]); publish()
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard let pointer, count > 0 else { return }
        let data = Data(bytes: pointer, count: count)
        if Thread.isMainThread { receive(data) } else { DispatchQueue.main.async { [weak self] in self?.receive(data) } }
    }
    private func receive(_ data: Data) {
        guard !stopping else { return }; bytes += data.count
        if let raw {
            do { try raw.write(contentsOf: data) } catch { log.add("原始文件写入失败：\(error.localizedDescription)"); stopCapture() }
        }
        let discarded = parser.discardedBytes
        let packets = parser.feed(data)
        if discarded != parser.discardedBytes { statusParser.resetFraming(); hotkeyDetector.resetBaseline() }
        for packet in packets {
            envelopes += 1; blocks += packet.blocks.count
            for block in packet.blocks {
                let oldGaps = statusParser.sequenceGaps, oldInvalid = statusParser.invalidBlocks
                let statuses = statusParser.feed(block)
                if oldGaps != statusParser.sequenceGaps || oldInvalid != statusParser.invalidBlocks { hotkeyDetector.resetBaseline() }
                for status in statuses {
                    statusFrames += 1
                    for key in hotkeyDetector.observe(status, at: now) {
                        log.add("SPP 热键：\(key.title)", fields: ["source": key == .connection ? "capture" : "denoise_state_change", "statusFrame": statusFrames])
                        hotkey?(key)
                    }
                    currentStatus = status; lastStatusTime = now
                    if var pending = pendingDenoise {
                        if pending.observe(status.denoise, at: now) {
                            pendingDenoise = nil
                            denoiseResult = "状态回读确认：降噪" + (status.denoise ? "开启" : "关闭")
                            log.add(denoiseResult, fields: ["hex": status.bytes.hex, "statusFrame": statusFrames])
                        } else { pendingDenoise = pending }
                    }
                    if status.capture == 1 {
                        captureEvents += 1
                        log.add("SPP capture 连接键候选事件", fields: ["count": captureEvents, "statusFrame": statusFrames, "hex": status.bytes.hex])
                    }
                    if lastStatus != status.bytes {
                        log.add("SPP 状态快照", fields: ["hex": status.bytes.hex, "capture": status.capture, "denoise": status.denoise])
                        lastStatus = status.bytes
                    }
                }
            }
            if let frame = packet.control {
                log.add("SPP DUML", fields: ["hex": frame.bytes.hex]); controlFrame?(frame)
                if let (query, _) = pendingExit {
                    do {
                        if try query.reply(frame.bytes) != nil {
                            pendingExit = nil; exitAcknowledged = true
                            commandResults = ["12/65 ACK 00：已确认，关闭 SPP 通道"]
                            log.add(commandResults[0]); commandUpdate?(commandResults[0], true)
                            DispatchQueue.main.async { [weak self] in self?.stop() }
                        }
                    } catch {
                        pendingExit = nil
                        commandResults = ["12/65 回应失败：\(error.localizedDescription)"]
                        log.add(commandResults[0]); commandUpdate?(commandResults[0], false)
                    }
                }
                if let (command, sequence, _) = pendingCommand, command.matches(frame, sequence: sequence) {
                    let success: Bool
                    switch command {
                    case .clockStart: success = frame.payload == [0, 1]
                    case .clockStop: success = frame.payload.count == 8 && Array(frame.payload.prefix(2)) == [0, 2]
                    case .version: success = (try? Mini2Request(.version, sequence: sequence).validate(frame)) != nil
                    case .battery: success = (try? Mini2Request(.battery, sequence: sequence).validate(frame)) != nil
                    }
                    commandResults.append("\(command.rawValue)：\(success ? "有效回应" : "回应格式不符")")
                    if command == .clockStop, success { clockArmed = false }
                    log.add(commandResults.last!); pendingCommand = nil; sendNextCommand()
                }
            }
            if let wav, let decoder {
                for block in packet.blocks {
                    guard let payload = mini2AudioPayload(block) else { unknownBlocks += 1; continue }
                    let sequence = block[block.startIndex + 12]
                    if let lastAudioSequence, sequence != lastAudioSequence &+ 1 { sequenceGaps += 1 }
                    lastAudioSequence = sequence
                    do {
                        let pcm = try decoder.decode(payload)
                        try wav.append(pcm); decodedFrames += 1
                    } catch {
                        decodeErrors += 1
                        // Preserve elapsed duration on invalid frames; retain raw input for analysis.
                        do { try wav.append([Float](repeating: 0, count: 240)) }
                        catch { log.add("WAV 写入失败：\(error.localizedDescription)"); stopCapture(); break }
                    }
                }
            }
        }
    }
    func verifyCommands() {
        guard opened, !stopping, pendingExit == nil, !exitAcknowledged,
              pendingCommand == nil, pendingDenoise == nil, commandQueue.isEmpty else { return }
        commandResults = []; commandQueue = [.clockStart, .clockStop, .version, .battery]
        sendNextCommand()
    }
    func setDenoise(_ enabled: Bool) {
        guard opened, !stopping, pendingExit == nil, !exitAcknowledged, pendingCommand == nil, commandQueue.isEmpty,
              pendingDenoise == nil, now - lastStatusTime < 2,
              let currentStatus, currentStatus.denoise != enabled,
              let channel = channels.values.first(where: { !closedIDs.contains(UInt64($0.getObjectID())) }) else { return }
        var bytes = mini2DenoisePacket(enabled: enabled)
        pendingDenoise = Mini2DenoiseConfirmation(target: enabled, sentAt: now)
        hotkeyDetector.softwareDenoiseWrite(at: now)
        denoiseResult = "等待降噪" + (enabled ? "开启" : "关闭") + "状态回读…"
        let count = bytes.count
        let rc = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16(count)) }
        log.add("SPP TX 无线 19/11 降噪", fields: ["enabled": enabled, "hex": bytes.hex, "result": rc])
        if rc != 0 { pendingDenoise = nil; denoiseResult = "降噪指令写入失败：\(rc)"; log.add(denoiseResult) }
        publish()
    }
    func exitSPP() {
        guard opened, !stopping, pendingExit == nil, !exitAcknowledged,
              pendingCommand == nil, pendingDenoise == nil, commandQueue.isEmpty, !clockArmed,
              let channel = channels.values.first(where: { !closedIDs.contains(UInt64($0.getObjectID())) }) else { return }
        do {
            let peer = IOBluetoothHostController.default()?.addressAsString()?.replacingOccurrences(of: "-", with: ":")
            commandSequence &+= 1
            let query = try MicControlQuery(command: .deleteSPPReconnect, sequence: commandSequence, peerAddress: peer)
            var packet = query.packet
            pendingExit = (query, now + 5)
            commandResults = ["等待 12/65 ACK…"]
            commandUpdate?(commandResults[0], true)
            let count = packet.count
            let rc = packet.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16(count)) }
            log.add("SPP TX 12/65 清除本 Mac 重连记录", fields: ["hex": packet.hex, "result": rc, "sequence": commandSequence])
            if rc != 0 {
                pendingExit = nil; commandResults = ["12/65 写入失败：\(rc)"]
                log.add(commandResults[0]); commandUpdate?(commandResults[0], false)
            }
        } catch {
            commandResults = ["12/65 未发送：\(error.localizedDescription)"]
            log.add(commandResults[0]); commandUpdate?(commandResults[0], false)
        }
        publish()
    }
    private func write(_ command: Mini2SPPCommand, sequence: UInt16) -> IOReturn {
        guard opened, let channel = channels.values.first(where: { !closedIDs.contains(UInt64($0.getObjectID())) }) else { return -1 }
        var bytes = command.packet(sequence: sequence)
        let count = bytes.count
        let rc = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16(count)) }
        log.add("SPP TX \(command.rawValue) seq=\(sequence)", fields: ["hex": bytes.hex, "result": rc])
        return rc
    }
    private func sendNextCommand() {
        guard !stopping else { return }
        while !commandQueue.isEmpty {
            let command = commandQueue.removeFirst(); commandSequence &+= 1
            let sequence = commandSequence
            // Install pending before writing: a response can arrive reentrantly.
            pendingCommand = (command, commandSequence, now + 4)
            if command == .clockStart { clockArmed = true }
            let rc = write(command, sequence: sequence)
            if rc != 0 { pendingCommand = nil; commandResults.append("\(command.rawValue)：写入失败 \(rc)"); continue }
            guard pendingCommand?.1 == sequence else { return }
            commandUpdate?((commandResults + ["等待 \(command.rawValue)…"]).joined(separator: " · "), true)
            return
        }
        commandUpdate?(commandResults.joined(separator: " · "), false)
    }
    func toggleCapture() {
        if raw != nil { stopCapture(); return }
        guard opened, !stopping else { return }
        let url = log.directory.appendingPathComponent("spp-\(UUID().uuidString).bin")
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            raw = try FileHandle(forWritingTo: url); rawDeadline = now + 60
            decodedFrames = 0; decodeErrors = 0; unknownBlocks = 0; sequenceGaps = 0; lastAudioSequence = nil
            decoder = try LC3Decoder()
            wav = try WAVWriter(url: url.deletingPathExtension().appendingPathExtension("wav"))
            log.add("开始保存 SPP 原始数据（最长 60 秒）", fields: ["file": url.lastPathComponent])
        } catch { log.add("不能创建录音文件：\(error.localizedDescription)"); stopCapture() }
        publish()
    }
    private func stopCapture() {
        guard let handle = raw else { return }; raw = nil
        do { try handle.close() } catch { log.add("关闭原始文件失败：\(error.localizedDescription)") }
        do { try wav?.finish() } catch { log.add("WAV 完成失败：\(error.localizedDescription)") }
        wav = nil; decoder = nil
        log.add("WAV 保存结束", fields: ["decodedFrames": decodedFrames, "decodeErrors": decodeErrors,
                "unknownBlocks": unknownBlocks, "sequenceGaps": sequenceGaps])
        log.add("SPP 原始数据保存结束"); publish()
    }
    func stop(completion: ((Bool) -> Void)? = nil) {
        if let outcome { completion?(outcome != .unconfirmed); return }
        if completion != nil { closeCompletion = completion }
        guard !stopping else { return }
        if clockArmed, opened { commandSequence &+= 1; _ = write(.clockStop, sequence: commandSequence); clockArmed = false }
        commandQueue = []; pendingCommand = nil; commandUpdate?(commandResults.joined(separator: " · "), false)
        pendingExit = nil
        if pendingDenoise != nil { pendingDenoise = nil; denoiseResult = "连接关闭，降噪验证已取消"; log.add(denoiseResult) }
        stopping = true; stopCapture()
        log.add(exitAcknowledged ? "12/65 ACK 00 后关闭本地 SPP 通道；不主动断开系统蓝牙" : "关闭本地 SPP 通道；未确认 12/65，不主动断开系统蓝牙")
        closer.stop(now: now); publish()
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) { observedClose(channel) }
    @objc private func closeNotice(_ note: IOBluetoothUserNotification!, channel: IOBluetoothRFCOMMChannel!) { observedClose(channel) }
    private func observedClose(_ channel: IOBluetoothRFCOMMChannel?) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.observedClose(channel) }; return }
        guard let channel else { return }
        let id = UInt64(channel.getObjectID()); closedIDs.insert(id)
        closer.channelClosed(id: id)
        if outcome == .unconfirmed, !channels.isEmpty, Set(channels.keys).isSubset(of: closedIDs) {
            closed(.confirmed)
        }
        if !stopping { message = "SPP 通道已关闭"; stop() }
    }
    private func closed(_ result: RFCOMMCloseCoordinator.Outcome) {
        outcome = result; opened = false
        if result != .unconfirmed { timer?.invalidate(); timer = nil }
        message = result == .unconfirmed ? "SPP 关闭尚未确认" : "SPP 通道已关闭"
        log.add(message); publish()
        let completion = closeCompletion; closeCompletion = nil; completion?(result != .unconfirmed)
        if !completed || result == .confirmed { completed = true; finished?(result != .unconfirmed) }
    }
    private func publish() {
        let fresh = opened && !stopping && now - lastStatusTime < 2
        denoiseUpdate?(fresh ? currentStatus?.denoise : nil,
                       fresh && currentStatus != nil && pendingExit == nil && !exitAcknowledged && pendingDenoise == nil && pendingCommand == nil && commandQueue.isEmpty,
                       pendingDenoise != nil, denoiseResult,
                       fresh ? (currentStatus.map { $0.denoiseButtonDisabled ? "禁用" : "允许" } ?? "—") : "—")
        let denoise = lastStatus.map { $0[11] & 0x80 != 0 ? "开启" : "关闭" } ?? "—"
        statusUpdate?(captureEvents, "有效状态 \(statusFrames) 帧 · 降噪 \(denoise) · 序号缺口 \(statusParser.sequenceGaps) · 无效块 \(statusParser.invalidBlocks) · 重复块 \(statusParser.duplicateBlocks)")
        update?(message, opened, raw != nil, "\(bytes) 字节 · \(envelopes) 个封装 · \(blocks) 个无线子块 · 跳过 \(parser.discardedBytes) 字节")
    }
}
