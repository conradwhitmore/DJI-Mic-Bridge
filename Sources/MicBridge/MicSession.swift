import Foundation
import IOBluetooth
import MicLinkCore

final class MicSession: NSObject, IOBluetoothRFCOMMChannelDelegate {
    let device: IOBluetoothDevice
    let eventLog: URL
    let connectionID = UUID().uuidString
    var update: ((String, Double, Float, Int) -> Void)?
    // Connection lifetime is independent of every WAV segment.
    var complete: ((MicSession, String, Bool) -> Void)?
    var recordingComplete: ((URL?, String) -> Void)?
    var unexpectedStop: (() -> Void)?
    var audioSamples: (([Float]) -> Void)?
    var keyTestEvent: ((MicKeyTestEvent) -> Void)?
    private(set) var keyTestMayBeActive = false
    private var lastKeyTestSequence: UInt16?
    var buttonEvent: ((MicButtonEvent) -> Void)?
    var controlUpdate: ((String) -> Void)?
    var queryCompleted: ((MicControlCommand, Result<[UInt8], Error>) -> Void)?
    var controlResult: ((MicControlCommand, Bool) -> Void)?
    var batteryUpdate: ((Int) -> Void)?
    private(set) var controlFramesReceived = 0, statusFramesReceived = 0
    private var nextControlDiagnostic: TimeInterval = 0
    private var controlKinds: Set<String> = []
    private var exitAcknowledged = false
    var beforeReconnectDeletion: (() throws -> Void)?
    private var query: MicControlQuery?, queryDeadline: TimeInterval?
    private var queryChannel: IOBluetoothRFCOMMChannel?
    private var nextQuerySequence = UInt16.random(in: 1...60000)
    private var commandBuffers: [NSMutableData] = []
    private var pendingWrite: UnsafeMutableRawPointer?
    private var statusRouteSeen = false
    private(set) var reconnectDeleteSent = false
    var canQuery: Bool { canRecord && statusRouteSeen && query == nil && pendingWrite == nil && commandBuffers.count < 32 }
    var controlIdle: Bool { query == nil && pendingWrite == nil }
    var canRecoverKeyTest: Bool { canRecord && query == nil && pendingWrite == nil && commandBuffers.count < 32 }
    private var buttonEvents: [MicButtonEvent] = []
    private let parser = FrameParser(requireContinuousAudio: false), buttons = MicButtonDetector()
    private let decoder: LC3Decoder
    private let recorder = RecordingSegments()
    private var recordingStarted: TimeInterval?
    private var recordingDuration: TimeInterval = 0
    private var savedSeconds: Double = 0
    var isRecording: Bool { recorder.isRecording }
    var isClosing: Bool { stopping }
    var canRecord: Bool { openedAt != nil && lastRX != nil && !stopping }
    private let routes: AudioRoutes
    private var channels: [UInt64: IOBluetoothRFCOMMChannel] = [:]
    private var closeNotifications: [UInt64: IOBluetoothUserNotification] = [:]
    private var timer: Timer?, openWork: DispatchWorkItem?
    private var openedAt: TimeInterval?, lastRX: TimeInterval?
    private var created = ProcessInfo.processInfo.systemUptime
    private var stoppedAt: TimeInterval?, shutdownOutcome: RFCOMMCloseCoordinator.Outcome?
    private var stopping = false, completed = false, retired = false, frames = 0, presses = 0
    private var linkHandle: BluetoothConnectionHandle?
    private(set) var endedByLinkLoss = false
    private var level: Float = 0
    private var finalReason = "", routeFailure: String?
    private var events: [[String: Any]] = []
#if HFP_DIAGNOSTIC
    private var hfpLease = HFPDiagnosticLease()
    private var hfpRecoveryUntil: TimeInterval = 0
    private var hfpLastSample: TimeInterval = 0
    private var hfpStopFile: URL { eventLog.appendingPathExtension("hfp-stop") }
    func beginHFPDiagnostic() throws {
        guard canRecord, !isRecording, !retired, hfpLease.begin(now: now) else {
            throw StreamError.invalid("本轮诊断只能启用一次，且需要 SPP 正常接收、未录音")
        }
        record("hfp_diagnostic_started", ["seconds": 30, "stop_file": hfpStopFile.path,
                                         "stream_frame_offset": frames])
    }
    private func endHFPDiagnostic(_ reason: String) {
        guard hfpLease.deadline != nil else { return }
        hfpLease.end(); hfpRecoveryUntil = now + 3
        record("hfp_diagnostic_ended", ["reason": reason, "stream_frame_offset": frames])
        do { try routes.restoreLockedDefaults(); record("hfp_diagnostic_input_restored") }
        catch { record("hfp_diagnostic_restore_failed", ["error": error.localizedDescription]) }
    }
#endif
    private lazy var shutdown = RFCOMMCloseCoordinator(
        timeout: 8,
        requestClose: { [weak self] id in
            guard let self, !self.retired, let channel = self.channels[id] else { return -1 }
            // isOpen == false also means opening: cancellation must still request close.
            self.record("close_requested", ["object_id": id])
            let status = channel.close()
            self.record("close_returned", ["object_id": id, "status": Int(status)])
            return Int32(status)
        },
        onOutcome: { [weak self] result in
            guard let self else { return }
            self.shutdownOutcome = result
            self.record("shutdown_outcome", ["outcome": String(describing: result)])
        })

    init(device: IOBluetoothDevice, eventLog: URL) throws {
        self.device = device; self.eventLog = eventLog
        guard let address = device.addressString else { throw StreamError.invalid("设备没有蓝牙地址") }
        routes = AudioRoutes(target: address)
        decoder = try LC3Decoder()
        super.init()
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func record(_ kind: String, _ fields: [String: Any] = [:]) {
        var event = fields
        event["kind"] = kind; event["elapsed"] = now - created
        event["epoch"] = Date().timeIntervalSince1970
        event["connection_id"] = connectionID
        events.append(event)
        let url = eventLog
        if let data = try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]) {
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { /* Recording remains usable if diagnostic persistence fails. */ }
        }
    }
    func start() throws {
        guard device.isConnected() else { throw StreamError.invalid("请先在 macOS 蓝牙设置连接 Mic 2") }
        try routes.lock()
        record("audio_routes_locked", ["description": routes.description])
        linkHandle = device.connectionHandle
        created = now
        update?("准备 SPP · \(routes.description)", 0, 0, 0)
        ensureTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping else { return }
            do { try self.routes.check(requirePresent: true) }
            catch { self.stop(error.localizedDescription); return }
            self.shutdown.openingStarted()
            self.record("open_requested")
            var requested: IOBluetoothRFCOMMChannel?
            let status = self.device.openRFCOMMChannelAsync(&requested, withChannelID: 10, delegate: self)
            if let requested { self.track(requested) }
            self.record("open_request_returned", ["status": Int(status)])
            if status != 0 {
                self.shutdown.openingRequestFailed()
                self.stop("SPP 打开请求失败：\(status)")
            }
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    @discardableResult private func track(_ channel: IOBluetoothRFCOMMChannel, announce: Bool = true) -> UInt64 {
        let id = UInt64(channel.getObjectID())
        if channels[id] == nil {
            channels[id] = channel
            let notice = channel.register(forChannelCloseNotification: self,
                                          selector: #selector(observedChannelClosed(_:channel:)))
            if let notice { closeNotifications[id] = notice }
            else { record("close_notification_unavailable", ["object_id": id]) }
        }
        if announce { shutdown.channelAvailable(id: id) }
        return id
    }
    private func tick() {
        guard !retired else { return }
        if let deadline = queryDeadline, now >= deadline {
            finishQuery("指令应答超时；SPP 保持连接", kind: "control_timeout")
        }
        if !device.isConnected() || (linkHandle != nil && device.connectionHandle != linkHandle) {
            retireForLinkLoss(); return
        }
        if stopping {
            do { try routes.check(requirePresent: false) }
            catch {
                let text = error.localizedDescription
                if routeFailure != text { routeFailure = text; record("route_restore_failed", ["error": text]) }
            }
            shutdown.tick(now: now)
            guard let outcome = shutdownOutcome, let stoppedAt else { return }
            // A bounded route hold is additional protection, never close confirmation.
            if outcome == .notOpened || now - stoppedAt >= 4 { finish(outcome) }
            return
        }
#if HFP_DIAGNOSTIC
        if let deadline = hfpLease.deadline {
            if now >= deadline { endHFPDiagnostic("30_second_deadline") }
            else if FileManager.default.fileExists(atPath: hfpStopFile.path) { endHFPDiagnostic("external_watchdog") }
            else if now - (lastRX ?? now) > 5 { endHFPDiagnostic("spp_audio_stalled") }
            else if now - hfpLastSample >= 1 {
                hfpLastSample = now
                record("hfp_diagnostic_sample", ["stream_frame_offset": frames,
                                                "last_rx_age": now - (lastRX ?? now)])
            }
        }
        let allowInput = hfpLease.allowsInput(now: now)
        do { try routes.check(requirePresent: true, allowTargetAudio: allowInput || now < hfpRecoveryUntil,
                              allowDefaultInput: allowInput) }
        catch { stop(error.localizedDescription); return }
#else
        do { try routes.check(requirePresent: true) } catch { stop(error.localizedDescription); return }
#endif
        if let openedAt {
            if now >= nextControlDiagnostic {
                nextControlDiagnostic = now + 10
                record("control_health", ["audio_frames": frames, "control_frames": controlFramesReceived,
                                          "status_frames": statusFramesReceived, "route_ready": statusRouteSeen])
            }
            if let recordingStarted, now - recordingStarted >= recordingDuration {
                stopRecording("定时录音完成")
            }
            if now - (lastRX ?? openedAt) > 5 {
#if HFP_DIAGNOSTIC
                if now < hfpRecoveryUntil { return }
#endif
                stop("连续 5 秒未收到音频"); return
            }
            let seconds = isRecording ? Double(recorder.samples) / 48000 : savedSeconds
            update?(isRecording ? "正在保存录音 · SPP 保持连接" : "SPP 已连接 · 正在接收，未保存音频", seconds, level, presses)
        } else if now - created > 12 { stop("SPP 打开超时") }
    }
    func startRecording(output: URL, duration: TimeInterval) throws {
        guard canRecord else { throw StreamError.invalid("请先连接 SPP 并等待音频") }
        try recorder.start(url: output, seconds: duration)
        buttonEvents.removeAll(); recordingStarted = now; recordingDuration = duration; savedSeconds = 0
        record("recording_started", ["file": output.lastPathComponent, "limit_seconds": duration,
                                     "stream_frame_offset": frames])
        update?("正在保存录音 · SPP 保持连接", 0, level, presses)
    }
    func sendQuery(_ command: MicControlCommand, configuration: Mic2AudioConfiguration? = nil) throws {
        guard (command == .keyTestOff ? canRecoverKeyTest : canQuery), let channel = queryChannel, channel.isOpen() else {
            throw StreamError.invalid("请等待 SPP 状态就绪和上一条指令完成")
        }
        try routes.check(requirePresent: true)
        var peer: String?
        if command == .deleteSPPReconnect {
            guard !reconnectDeleteSent else { throw StreamError.invalid("本连接已发送过删除候选，不自动重复") }
            peer = IOBluetoothHostController.default()?.addressAsString()?.replacingOccurrences(of: "-", with: ":")
            guard let peer, AudioRoutes.normalized(peer) != AudioRoutes.normalized(device.addressString ?? "") else {
                throw StreamError.invalid("无法核对本 Mac 蓝牙地址")
            }
        }
        let request = try MicControlQuery(command: command, sequence: nextQuerySequence, peerAddress: peer,
                                          audioConfiguration: configuration)
        nextQuerySequence &+= 1
        let bytes = request.packet
        guard bytes.count <= Int(channel.getMTU()) else { throw StreamError.invalid("指令超过通道 MTU") }
        if command == .deleteSPPReconnect {
            guard let beforeReconnectDeletion else {
                throw StreamError.invalid("无法暂停自动连接，未发送 12/65")
            }
            try beforeReconnectDeletion()
            record("control_auto_reconnect_disabled", ["command": command.rawValue, "persisted": true])
        }
        let data = NSMutableData(data: Data(bytes))
        commandBuffers.append(data) // Retain until the matching asynchronous write completion.
        pendingWrite = data.mutableBytes
        if command == .keyTestOn { keyTestMayBeActive = true }
        if command == .deleteSPPReconnect { reconnectDeleteSent = true }
        query = request; queryDeadline = now + 8
        record("control_request", ["command": command.rawValue, "sequence": request.sequence,
                                   "packet_hex": bytes.map { String(format: "%02x", $0) }.joined(),
                                   "peer_address": peer ?? "", "peer_order": peer == nil ? "none" : "reversed_display_order"])
        controlUpdate?("\(command.title)…")
        let result = channel.writeAsync(data.mutableBytes, length: UInt16(bytes.count), refcon: data.mutableBytes)
        record("control_write_requested", ["status": Int(result)])
        if result != 0 { pendingWrite = nil; finishQuery("指令发送失败：\(result)；SPP 保持连接", kind: "control_write_failed") }
    }
    private func finishQuery(_ message: String, kind: String, fields: [String: Any] = [:], payload: [UInt8]? = nil) {
        guard let request = query else { return }
        var details = fields
        details["command"] = request.command.rawValue; details["sequence"] = request.sequence
        details["message"] = message
        record(kind, details)
        if request.command == .keyTestOff, payload != nil { keyTestMayBeActive = false }
        query = nil; queryDeadline = nil
        controlUpdate?(message)
        if request.command == .deleteSPPReconnect, kind == "control_reply" { exitAcknowledged = true }
        controlResult?(request.command, kind == "control_reply")
        let result: Result<[UInt8], Error> = payload.map { .success($0) } ?? .failure(StreamError.invalid(message))
        // Defer follow-up commands until the receive parser has returned.
        let callback = queryCompleted
        DispatchQueue.main.async { callback?(request.command, result) }
    }
    func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.rfcommChannelWriteComplete(channel, refcon: refcon, status: error) }; return
        }
        guard !retired, let refcon, refcon == pendingWrite, channel === queryChannel else { return }
        // Completed writes no longer own their buffers. Otherwise periodic read-only
        // battery queries would consume the 32-buffer limit and eventually block exit.
        commandBuffers.removeAll { $0.mutableBytes == refcon }
        pendingWrite = nil
        record("control_write_completed", ["status": Int(error)])
        if error != 0 { finishQuery("指令写入失败：\(error)；SPP 保持连接", kind: "control_write_failed") }
    }
    func stopRecording(_ reason: String = "录音已保存") {
        do {
            if let finished = try recorder.stop(reason: reason) { finishRecording(finished) }
        } catch {
            recordingStarted = nil
            record("recording_error", ["error": error.localizedDescription])
            recordingComplete?(nil, "保存失败：\(error.localizedDescription)")
        }
    }
    private func finishRecording(_ finished: RecordingSegments.Finished) {
        recordingStarted = nil; savedSeconds = Double(finished.samples) / 48000
        var message = finished.reason
        if let output = finished.url {
            do {
                let data = try JSONEncoder().encode(buttonEvents)
                let sidecar = output.deletingPathExtension().appendingPathExtension("buttons.json")
                try data.write(to: sidecar, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            } catch { message += "；按键记录保存失败：\(error.localizedDescription)" }
        }
        record("recording_stopped", ["file": finished.url?.lastPathComponent ?? "", "samples": finished.samples,
                                    "reason": finished.reason, "stream_frame_offset": frames])
        buttonEvents.removeAll()
        recordingComplete?(finished.url, message + (stopping ? "" : "；SPP 保持连接"))
    }
    /// Only call after an observed baseband loss/change, never to bypass close confirmation.
    /// Do not close stale channel objects: their remote IDs may be reused after reconnect.
    func retireForLinkLoss() {
        guard !retired else { return }
        finishQuery("蓝牙连接已断开，未完成指令不自动重发", kind: "control_cancelled")
#if HFP_DIAGNOSTIC
        endHFPDiagnostic("bluetooth_link_lost")
#endif
        retired = true; endedByLinkLoss = true; stopping = true
        openWork?.cancel(); openWork = nil
        timer?.invalidate(); timer = nil
        stopRecording("蓝牙断开，已结束本段录音")
        record("bluetooth_link_lost", ["previous_handle": linkHandle.map { Int($0) } ?? -1])
        for notice in closeNotifications.values { notice.unregister() }
        closeNotifications.removeAll()
        for channel in channels.values { _ = channel.setDelegate(nil) }
        channels.removeAll()
        var message = "蓝牙已断开，等待 Mic 2 重新连接"
        var routeFailed = false
        do { try routes.restoreLockedDefaults() }
        catch { routeFailed = true; message += "；路由恢复失败：\(error.localizedDescription)" }
        guard !completed else { return }
        completed = true
        record("connection_finished", ["reason": "baseband_lost", "recovery_required": routeFailed])
        let callback = complete; complete = nil
        callback?(self, message, routeFailed)
    }
    // BEGIN MICBRIDGE ACK EXIT
    /// Product completion rule: a validated 12/65 ACK authorizes local teardown.
    /// Keep the notification-based path below for unrelated transport failures.
    func closeAfterAcknowledgedExit() {
        guard exitAcknowledged, !retired, !completed else { return }
        stopping = true; retired = true
        openWork?.cancel(); openWork = nil
        timer?.invalidate(); timer = nil
        stopRecording("SPP 已断开")
        record("stop_requested", ["reason": "acknowledged_exit", "completion_basis": "12/65_ack00"])
        for notice in closeNotifications.values { notice.unregister() }
        closeNotifications.removeAll()
        for (id, channel) in channels {
            _ = channel.setDelegate(nil)
            record("close_requested", ["object_id": id])
            let result = channel.close()
            record("close_returned", ["object_id": id, "status": Int(result)])
        }
        channels.removeAll(); queryChannel = nil
        do { try routes.restoreLockedDefaults() }
        catch { record("route_restore_failed", ["error": error.localizedDescription]) }
        completed = true
        record("connection_finished", ["reason": "acknowledged_exit", "completion_basis": "12/65_ack00", "recovery_required": false])
        let callback = complete; complete = nil
        callback?(self, "SPP 已断开", false)
    }
    // END MICBRIDGE ACK EXIT
    func stop(_ reason: String = "已断开") {
        guard !stopping, !retired else { return }
        finishQuery("SPP 正在关闭，未完成指令不自动重发", kind: "control_cancelled")
#if HFP_DIAGNOSTIC
        endHFPDiagnostic("session_stop: \(reason)")
#endif
        if !device.isConnected() { retireForLinkLoss(); return }
        if reason != "SPP 通道已关闭" && reason != "用户断开 SPP" && reason != "App 退出" { unexpectedStop?() }
        stopping = true; stoppedAt = now; finalReason = reason
        openWork?.cancel(); openWork = nil
        stopRecording(reason)
        record("stop_requested", ["reason": reason])
        update?("\(reason) · 正在确认 SPP 关闭…", savedSeconds, 0, presses)
        ensureTimer()
        shutdown.stop(now: now)
    }
    private func finish(_ outcome: RFCOMMCloseCoordinator.Outcome) {
        guard !completed else { return }; completed = true
        timer?.invalidate(); timer = nil
        let unconfirmed = outcome == .unconfirmed
        if !unconfirmed {
            for notice in closeNotifications.values { notice.unregister() }
            closeNotifications.removeAll()
            for channel in channels.values { _ = channel.setDelegate(nil) }
            channels.removeAll()
        }
        // On timeout the App retains this session and its delegate, so a late-open
        // callback can still request bounded cleanup. No new capture is allowed.
        var message = finalReason
        if unconfirmed { message += "；SPP 关闭未确认，临时路由保护已结束。请关闭 Mic 2 并退出 App，暂勿启用系统录音" }
        else if outcome == .confirmed { message += "；SPP 通道已关闭" }
        if let routeFailure { message += "；音频收尾检查异常：\(routeFailure)" }
        record("connection_finished", ["recovery_required": unconfirmed || routeFailure != nil])
        let callback = complete; complete = nil
        callback?(self, message, unconfirmed || routeFailure != nil)
    }
    func rfcommChannelOpenComplete(_ opened: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.rfcommChannelOpenComplete(opened, status: error) }
            return
        }
        guard !retired else { return }
        // The completion status is the result of the open operation. Tracking may
        // trigger synchronous cleanup; isOpen afterwards cannot rewrite that result.
        let success = error == 0
        let openNow = opened?.isOpen() == true
        let id = opened.map { track($0, announce: false) }
        record("open_completed", ["status": Int(error), "success": success, "object_id": id ?? 0])
        shutdown.openingCompleted(id: id, success: success)
        if stopping { return }
        guard success else { stop("SPP 打开失败：\(error)"); return }
        guard opened != nil else { stop("SPP 报告打开成功但未返回通道，需确认关闭"); return }
        guard openNow else { stop("SPP 打开回调到达时通道已不在打开状态，需确认关闭"); return }
        guard openedAt == nil else { stop("意外重复打开"); return }
        openedAt = now
        queryChannel = opened
    }
    func rfcommChannelData(_ source: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard let pointer, count > 0, count <= 65536 else {
            DispatchQueue.main.async { [weak self] in self?.stop("无效接收长度") }
            return
        }
        let bytes = Data(bytes: pointer, count: count)
        if Thread.isMainThread { receive(bytes) }
        else { DispatchQueue.main.async { [weak self] in self?.receive(bytes) } }
    }
    private func receive(_ bytes: Data) {
        guard !stopping, openedAt != nil else { return }
        do {
            var receivedPCM: [Float] = []
            let previousGaps = parser.audioDiscontinuities
            let envelopes = try parser.feed(bytes)
            if parser.audioDiscontinuities != previousGaps,
               previousGaps < 20 || parser.audioDiscontinuities / 100 != previousGaps / 100 {
                record("audio_sequence_gap_ignored", ["count": parser.audioDiscontinuities])
            }
            for envelope in envelopes {
                for packet in envelope.audio {
                    let pcm = try decoder.decode(packet)
                    level = pcm.map(abs).max() ?? 0
                    frames += 1; lastRX = now
                    do {
                        if let finished = try recorder.append(pcm) { finishRecording(finished) }
                    } catch {
                        stopRecording("保存失败：\(error.localizedDescription)")
                        record("recording_error", ["error": error.localizedDescription])
                        recordingComplete?(nil, "保存失败：\(error.localizedDescription)；SPP 保持连接")
                    }
                    receivedPCM.append(contentsOf: pcm)
                }
                if let c = envelope.control {
                    if c.count >= 13, c[9] == 4, c[10] == 0x68 {
                        record("key_test_control", ["control_hex": c.map { String(format: "%02x", $0) }.joined()])
                    }
                    if let event = MicKeyTestEvent(frame: c), event.sequence != lastKeyTestSequence {
                        lastKeyTestSequence = event.sequence
                        record("key_test_event", ["button": event.button.rawValue, "sequence": event.sequence])
                        let key = MicButtonEvent(independent: event, time: Date().timeIntervalSince1970)
                        if event.button == .link { presses += 1 }
                        if isRecording { buttonEvents.append(key) }
                        keyTestEvent?(event)
                    }
                    controlFramesReceived += 1
                    let kind = "\(c.count):" + c[4...5].map { String(format: "%02x", $0) }.joined() + ":" + c[8...10].map { String(format: "%02x", $0) }.joined()
                    if controlKinds.count < 16, controlKinds.insert(kind).inserted {
                        record("control_kind_received", ["header": kind])
                    }
                    if c.count == 58, c[4] == 0x3a, c[5] == 2, c[8] == 0, c[9] == 2, c[10] == 0xff {
                        statusRouteSeen = true; statusFramesReceived += 1
                    }
                    if let request = query {
                        do {
                            if let payload = try request.reply(c) {
                                if request.command == .battery { batteryUpdate?(Int(payload[0])) }
                                finishQuery(request.summary(payload) + "；SPP 保持连接", kind: "control_reply",
                                            fields: ["control_hex": c.map { String(format: "%02x", $0) }.joined()], payload: payload)
                            }
                        } catch {
                            finishQuery(error.localizedDescription + "；SPP 保持连接", kind: "control_reply_rejected",
                                        fields: ["control_hex": c.map { String(format: "%02x", $0) }.joined()])
                        }
                    }
                    for event in buttons.observe(c, time: Date().timeIntervalSince1970) {
                        record("button_received", ["button": event.button.rawValue, "sequence": event.sequence,
                                                   "previous": event.previousValue, "value": event.value])
                        // Observer refreshes settings only; shortcuts use keyTestEvent.
                        buttonEvent?(event)
                    }
                }
            }
            if !receivedPCM.isEmpty { audioSamples?(receivedPCM) }
        } catch { stop(error.localizedDescription) }
    }
    private func didClose(_ source: IOBluetoothRFCOMMChannel?, notification: IOBluetoothUserNotification? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.didClose(source, notification: notification) }
            return
        }
        guard !retired, let source else { return }
        if !device.isConnected() { retireForLinkLoss(); return }
        let id = UInt64(source.getObjectID())
        guard channels[id] != nil else { return }
        // Use one source of closure evidence. Duplicate delegate/notification
        // callbacks must not confirm a later open of the same object.
        if let notification {
            guard closeNotifications[id] === notification else { return }
        } else if closeNotifications[id] != nil { return }
        guard !source.isOpen() else {
            record("stale_close_ignored", ["object_id": id]); return
        }
        record("close_observed", ["object_id": id])
        shutdown.channelClosed(id: id)
        if !stopping { stop("SPP 通道已关闭") }
    }
    @objc private func observedChannelClosed(_ notification: IOBluetoothUserNotification!, channel: IOBluetoothRFCOMMChannel!) {
        didClose(channel, notification: notification)
    }
    func rfcommChannelClosed(_ source: IOBluetoothRFCOMMChannel!) { didClose(source) }
}
