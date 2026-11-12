import AppKit
import AVFoundation
import IOBluetooth
import CoreAudio
import MicLinkCore

let args = CommandLine.arguments
if args.count == 5, args[1] == "--decode", args[3] == "--output" {
    do {
        let result = try decodeCapture(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[4]))
        print(String(data: try JSONEncoder().encode(result), encoding: .utf8)!)
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if args.count > 1 && !(args.count == 3 && ["--import-spp", "--open-wav"].contains(args[1])) {
    fputs("Usage: RXlessDemo [--decode input.bin --output output.wav | --import-spp input.bin | --open-wav recording.wav]\n", stderr)
    exit(2)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AVAudioPlayerDelegate {
    var window: NSWindow!
    let devicePicker = NSPopUpButton(), durationPicker = NSPopUpButton()
    let status = NSTextField(wrappingLabelWithString: "就绪。请选择已配对的 Mic 2，或导入已有 SPP 数据。")
    let resultLabel = NSTextField(wrappingLabelWithString: "尚无录音")
    let controlResult = NSTextField(wrappingLabelWithString: "指令验证：使用当前 SPP 连接，完成后保持接收")
    var queryButtons: [NSButton] = []
    var vibrationButtons: [NSButton] = []
    var vibrationTest: VibrationTest?
    var denoiseTest: DenoiseTest?
    var denoiseButtons: [NSButton] = []
    var keyTestButtons: [NSButton] = []
    var keyTestOperation: KeyTestOperation?
    let keyTestResult = NSTextField(wrappingLabelWithString: "04/68 独立事件：电源 0 · 录音 0 · 连接 0")
    var keyTestCounts: [MicButton: Int] = [:]
    let signalView = SignalView(frame: .zero)
    let buttonMonitor = ButtonMonitorView(frame: .zero)
    var playbackTimer: Timer?, playbackFile: AVAudioFile?
    let metrics = NSTextField(labelWithString: "0.0 秒 · 连接键候选事件 0 次")
    var startButton: NSButton!, stopButton: NSButton!, playButton: NSButton!, revealButton: NSButton!
    var importButton: NSButton!, refreshButton: NSButton!
    var connectButton: NSButton!, disconnectButton: NSButton!, autoConnectButton: NSButton!
    let autoPolicy = AutoSPPPolicy()
    var watchedDevice: IOBluetoothDevice?
    var watchedHandle: BluetoothConnectionHandle?
    var disconnectNotice: IOBluetoothUserNotification?
    var connectionMonitor: Timer?
    var devices: [IOBluetoothDevice] = []
    var session: MicSession?, player: AVAudioPlayer?
    // Keep unresolved delegates alive for bounded late-open cancellation.
    var unresolvedSessions: [MicSession] = []
    var captureBlocked = false
    var latest: URL?, importing = false, terminating = false, refreshing = false
    var recoveryWindow: NSPanel?
#if HFP_DIAGNOSTIC
    var hfpDiagnosticButton: NSButton!
    var hfpDiagnosticUsed = false
    @objc func beginHFPDiagnostic() {
        guard !hfpDiagnosticUsed, let session else { return }
        do {
            try session.beginHFPDiagnostic()
            hfpDiagnosticUsed = true
            // No reconnect loop during this trial. Do not persist this temporary choice.
            autoConnectButton.state = .off; autoPolicy.markAttempted()
            hfpDiagnosticButton.title = "本轮诊断已用（30 秒自动恢复输入）"
            updateControls()
        } catch { show(error.localizedDescription) }
    }
#endif

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 DJI Mic RXless Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 850), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "DJI Mic RXless Demo"; window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        let title = NSTextField(labelWithString: "DJI Mic · 免接收器录音")
        title.font = .systemFont(ofSize: 25, weight: .semibold); root.addArrangedSubview(title)
        root.addArrangedSubview(NSTextField(labelWithString: "实验性 Demo · 本地 WAV 录制与播放 · 无需 BlackHole"))
        let warning = NSTextField(wrappingLabelWithString: "使用前须知：SPP 实验可能使普通蓝牙 / HFP 收音失效或反复断连，退出 App 后也可能需要恢复配对。请关闭录音软件与系统输入电平页。SPP 连接期间保持非 DJI 系统音频路由。停止录音只结束文件，连接与电平继续保持；未录音时不保存声音。")
        warning.textColor = .systemOrange; warning.font = .systemFont(ofSize: 13, weight: .medium)
        root.addArrangedSubview(warning); warning.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
#if HFP_DIAGNOSTIC
        window.title = "DJI Mic RXless Demo · 单轮 HFP 诊断"
        hfpDiagnosticButton = button("允许系统 HFP 输入 30 秒（仅一次）", #selector(beginHFPDiagnostic))
        root.addArrangedSubview(hfpDiagnosticButton)
#endif
        let line = NSBox(); line.boxType = .separator; root.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        refreshButton = button("刷新设备", #selector(refresh))
        devicePicker.widthAnchor.constraint(equalToConstant: 395).isActive = true
        root.addArrangedSubview(row([NSTextField(labelWithString: "Mic 2"), devicePicker, refreshButton]))
        connectButton = button("连接 SPP", #selector(connectSPP)); disconnectButton = button("断开 SPP", #selector(disconnectSPP))
        autoConnectButton = NSButton(checkboxWithTitle: "蓝牙重连后自动连接 SPP", target: self, action: #selector(autoConnectChanged))
        autoConnectButton.state = UserDefaults.standard.object(forKey: "autoSPP") == nil || UserDefaults.standard.bool(forKey: "autoSPP") ? .on : .off
        devicePicker.target = self; devicePicker.action = #selector(deviceSelectionChanged)
        root.addArrangedSubview(row([connectButton, disconnectButton, autoConnectButton]))
        queryButtons = MicControlCommand.allCases.enumerated().map { index, command in
            let b = button(command.title, #selector(sendControlQuery(_:))); b.tag = index; return b
        }
        vibrationButtons = [button("关闭振动通知", #selector(setVibration(_:))), button("开启振动通知", #selector(setVibration(_:)))]
        vibrationButtons[0].tag = 0; vibrationButtons[1].tag = 1
        root.addArrangedSubview(row(Array(queryButtons.suffix(1)) + vibrationButtons))
        keyTestButtons = [button("进入按键测试", #selector(setKeyTest(_:))), button("退出按键测试", #selector(setKeyTest(_:)))]
        keyTestButtons[0].tag = 1; keyTestButtons[1].tag = 0
        root.insertArrangedSubview(row(Array(queryButtons.prefix(3)) + keyTestButtons), at: root.arrangedSubviews.count - 1)
        keyTestResult.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        denoiseButtons = [button("开启降噪", #selector(setDenoise(_:))), button("关闭降噪", #selector(setDenoise(_:)))]
        denoiseButtons[0].tag = 1; denoiseButtons[1].tag = 0
        root.addArrangedSubview(row(denoiseButtons))
        root.addArrangedSubview(keyTestResult)
        keyTestResult.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        queryButtons.last?.toolTip = "发送 12/65 子操作 1，尝试清除本 Mac 的重连记录；发送前关闭并保存自动连接开关，需手动恢复；ACK 不代表已退出 SPP。"
        controlResult.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(controlResult)
        controlResult.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        durationPicker.addItems(withTitles: ["10 秒", "30 秒", "60 秒"])
        startButton = button("开始录音", #selector(startCapture)); stopButton = button("停止录音", #selector(stopCapture))
        root.addArrangedSubview(row([NSTextField(labelWithString: "限时"), durationPicker, startButton, stopButton]))
        root.addArrangedSubview(signalView)
        signalView.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        signalView.heightAnchor.constraint(equalToConstant: 182).isActive = true
        root.addArrangedSubview(buttonMonitor)
        buttonMonitor.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        buttonMonitor.heightAnchor.constraint(equalToConstant: 110).isActive = true
        root.addArrangedSubview(metrics)
        status.font = .systemFont(ofSize: 13); status.textColor = .secondaryLabelColor
        root.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        importButton = button("导入 SPP 文件…", #selector(importSPP)); playButton = button("播放录音", #selector(play)); revealButton = button("在 Finder 中显示", #selector(reveal))
        root.addArrangedSubview(row([importButton, playButton, revealButton]))
        resultLabel.font = .systemFont(ofSize: 12); resultLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(resultLabel); resultLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let foot = NSTextField(wrappingLabelWithString: "仅针对已验证的 Mic 2 SPP 格式。48 kHz 单声道 PCM 输出；不代表接收器等效音质。三个实体键显示候选反馈，不发送快捷键。")
        foot.font = .systemFont(ofSize: 11); foot.textColor = .secondaryLabelColor
        root.addArrangedSubview(foot); foot.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        devicePicker.addItem(withTitle: "点击刷新读取已配对的 Mic 2")
        updateControls()
        connectionMonitor = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.monitorConnection() }
        RunLoop.main.add(connectionMonitor!, forMode: .common)
        // File-only launches must not attach to Bluetooth implicitly.
        if args.count == 1 { refresh() }
        else { autoConnectButton.state = .off }
        if args.count == 3 {
            let url = URL(fileURLWithPath: args[2])
            if args[1] == "--import-spp" { importFile(url) }
            else {
                do {
                    let file = try AVAudioFile(forReading: url)
                    guard file.processingFormat.sampleRate == 48000, file.processingFormat.channelCount == 1 else { throw StreamError.invalid("需要 48 kHz 单声道 WAV") }
                    setRecording(url); status.stringValue = "已打开本地录音；点击播放可查看对应波形。"; updateControls()
                } catch { show(error.localizedDescription) }
            }
        }
    }
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func row(_ views: [NSView]) -> NSStackView { let s = NSStackView(views: views); s.spacing = 10; s.alignment = .centerY; return s }
    func updateControls() {
        let connected = session != nil, recording = session?.isRecording == true
        for b in queryButtons {
            b.isEnabled = keyTestOperation == nil && denoiseTest == nil && session?.keyTestMayBeActive != true && vibrationTest == nil && session?.canQuery == true && !(MicControlCommand.allCases[b.tag] == .deleteSPPReconnect && session?.reconnectDeleteSent == true)
        }
        for b in vibrationButtons { b.isEnabled = keyTestOperation == nil && denoiseTest == nil && session?.keyTestMayBeActive != true && vibrationTest == nil && session?.canQuery == true && !recording }
        for b in denoiseButtons { b.isEnabled = keyTestOperation == nil && denoiseTest == nil && vibrationTest == nil && session?.canQuery == true && !recording }
        for b in keyTestButtons {
            b.isEnabled = keyTestOperation == nil && denoiseTest == nil && vibrationTest == nil && !recording &&
                (b.tag == 0 ? session?.canRecoverKeyTest == true : session?.canQuery == true && session?.keyTestMayBeActive != true)
        }
#if HFP_DIAGNOSTIC
        hfpDiagnosticButton?.isEnabled = !hfpDiagnosticUsed && session?.canRecord == true && !recording
        if hfpDiagnosticUsed { autoConnectButton.isEnabled = false }
#endif
        connectButton.isEnabled = !connected && !importing && !captureBlocked && !devices.isEmpty && !refreshing
        disconnectButton.isEnabled = connected && session?.isClosing == false && keyTestOperation == nil && denoiseTest == nil && session?.keyTestMayBeActive != true
        startButton.isEnabled = keyTestOperation == nil && denoiseTest == nil && vibrationTest == nil && session?.canRecord == true && !recording && !importing
        startButton.toolTip = captureBlocked ? "连接收尾未确认；请关闭 Mic 2 后退出 App。" : "只保存当前音频，不重新连接蓝牙。"
        stopButton.isEnabled = recording
        devicePicker.isEnabled = !connected && !importing
        durationPicker.isEnabled = !recording && session?.isClosing != true
        refreshButton.isEnabled = !connected && !importing && !refreshing && !captureBlocked
        importButton.isEnabled = !connected && !importing
        playButton.isEnabled = !recording && !importing && latest != nil && session?.isClosing != true
        revealButton.isEnabled = latest != nil
    }
    @objc func refresh() {
        guard !refreshing, session == nil, !importing, !captureBlocked else { return }
        refreshing = true; status.stringValue = "正在读取已配对设备…"; updateControls()
        // macOS 27's IOBluetooth coordinator can wait on the main queue during
        // first initialization. Never make the first pairedDevices call there.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter {
                let name = ($0.name ?? "").uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
                return name.contains("DJIMIC2")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.devices = paired; self.refreshing = false
                self.devicePicker.removeAllItems()
                if paired.isEmpty { self.devicePicker.addItem(withTitle: "未找到已配对的 DJI Mic 2") }
                else { for d in paired { self.devicePicker.addItem(withTitle: "\(d.name ?? "Mic 2") · \(d.isConnected() ? "已连接" : "未连接")") } }
                let remembered = UserDefaults.standard.string(forKey: "selectedMic2")
                if let index = paired.firstIndex(where: { $0.addressString == remembered }) {
                    self.devicePicker.selectItem(at: index); self.deviceSelectionChanged()
                } else if paired.count == 1 {
                    self.devicePicker.selectItem(at: 0); self.deviceSelectionChanged()
                } else {
                    self.status.stringValue = paired.isEmpty ? "等待已配对的 Mic 2；可点击刷新设备。" : "请选择要自动连接的 Mic 2。"
                }
                self.updateControls()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+10) { [weak self] in
            guard let self, self.refreshing, !self.importing else { return }
            self.status.stringValue = "蓝牙服务尚未返回；可继续离线导入，或退出 App。没有打开 SPP。"
        }
    }
    @objc func deviceSelectionChanged() {
        guard session == nil, devices.indices.contains(devicePicker.indexOfSelectedItem) else { return }
        let selected = devices[devicePicker.indexOfSelectedItem]
        guard watchedDevice?.addressString != selected.addressString else { return }
        disconnectNotice?.unregister(); disconnectNotice = nil
        watchedDevice = selected; watchedHandle = nil; autoPolicy.linkDisconnected()
        UserDefaults.standard.set(selected.addressString, forKey: "selectedMic2")
        status.stringValue = "已选择 Mic 2，等待蓝牙连接。"
    }
    @objc func autoConnectChanged() {
        UserDefaults.standard.set(autoConnectButton.state == .on, forKey: "autoSPP")
        autoPolicy.linkDisconnected()
        if autoConnectButton.state == .off && session == nil { status.stringValue = "自动连接已暂停。" }
    }
    func handleBluetoothLoss() {
        autoPolicy.linkDisconnected(); watchedHandle = nil
        disconnectNotice?.unregister(); disconnectNotice = nil
        // Baseband loss invalidates old RFCOMM objects. Never close them after a new link appears.
        captureBlocked = false
        let oldUnresolved = unresolvedSessions; unresolvedSessions.removeAll()
        for old in oldUnresolved { old.retireForLinkLoss() }
        session?.retireForLinkLoss()
        if !captureBlocked && session == nil { status.stringValue = "蓝牙已断开，等待 Mic 2 重新连接。" }
        updateControls()
    }
    @objc func bluetoothDisconnected(_ notice: IOBluetoothUserNotification!, device: IOBluetoothDevice!) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.bluetoothDisconnected(notice, device: device) }; return
        }
        guard let notice, disconnectNotice === notice,
              device?.addressString == watchedDevice?.addressString else { return }
        handleBluetoothLoss()
    }
    func monitorConnection() {
        guard !terminating, !importing, let device = watchedDevice else { return }
        let connected = device.isConnected()
        if devices.indices.contains(devicePicker.indexOfSelectedItem),
           devices[devicePicker.indexOfSelectedItem].addressString == device.addressString {
            devicePicker.selectedItem?.title = "\(device.name ?? "Mic 2") · \(connected ? "已连接" : "未连接")"
        }
        if !connected {
            if watchedHandle != nil || session != nil { handleBluetoothLoss() }
            _ = autoPolicy.shouldConnect(enabled: autoConnectButton.state == .on, connected: false,
                                         ready: false, busy: false, now: ProcessInfo.processInfo.systemUptime)
            return
        }
        if let previous = watchedHandle, previous != device.connectionHandle { handleBluetoothLoss() }
        if watchedHandle == nil && session == nil && !captureBlocked {
            status.stringValue = autoConnectButton.state == .on ? "蓝牙已连接，等待设备就绪后自动连接 SPP。" : "蓝牙已连接；自动连接已暂停。"
        }
        watchedHandle = device.connectionHandle
        if disconnectNotice == nil {
            disconnectNotice = device.register(forDisconnectNotification: self, selector: #selector(bluetoothDisconnected(_:device:)))
        }
        guard session == nil, !captureBlocked else { return }
        let reader = AudioRoutes(target: device.addressString ?? "")
        var ready = false
        do {
            let targets = try reader.devices().filter { try reader.isTarget($0) }
            let allIdle = try targets.allSatisfy { try reader.integer($0, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 }
            ready = !targets.isEmpty && allIdle
        } catch { ready = false }
        if autoPolicy.shouldConnect(enabled: autoConnectButton.state == .on, connected: true,
                                    ready: ready, busy: session != nil, now: ProcessInfo.processInfo.systemUptime) {
            connectSPP()
        }
    }
    func newRecording() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("DJIMicRXlessDemo/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent("Mic2-\(stamp)-\(UUID().uuidString.prefix(6)).wav")
    }
    func stopPlayback() {
        player?.stop(); player = nil; playbackTimer?.invalidate(); playbackTimer = nil; playbackFile = nil
        if session != nil && session?.isClosing == false { signalView.begin() } else { signalView.end() }
        playButton.title = "播放录音"
    }
    func updatePlaybackWaveform() {
        guard let player, player.isPlaying, let file = playbackFile else { return }
        let target = min(file.length, AVAudioFramePosition(player.currentTime * file.processingFormat.sampleRate))
        if target - file.framePosition > 9600 { file.framePosition = target - 9600 }
        let count = target - file.framePosition
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            if let samples = buffer.floatChannelData?[0] { signalView.append(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))) }
        } catch { playbackTimer?.invalidate(); playbackTimer = nil; signalView.end() }
    }
    func newConnectionLog() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
            .appendingPathComponent("DJIMicRXlessDemo/Connections", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent("Connection-\(UUID().uuidString).session.json")
    }
    @objc func connectSPP() {
        guard session == nil, !captureBlocked, !importing, devices.indices.contains(devicePicker.indexOfSelectedItem) else { return }
        deviceSelectionChanged()
        autoPolicy.markAttempted()
        stopPlayback()
        do {
            let connection = try MicSession(device: devices[devicePicker.indexOfSelectedItem], eventLog: try newConnectionLog())
            session = connection; signalView.begin(); buttonMonitor.begin()
            controlResult.stringValue = "指令验证：等待当前连接就绪"
            connection.beforeReconnectDeletion = { [weak self] in
                guard let self else { throw StreamError.invalid("Demo 已退出，未发送 12/65") }
                // Persist before writeAsync: a reply or link-loss callback may arrive immediately.
                // Reuse the normal toggle so ACL changes and app relaunch cannot re-enable it.
                self.autoConnectButton.state = .off
                self.autoConnectChanged()
            }
            connection.controlUpdate = { [weak self, weak connection] message in
                guard let self else { return }
                let paused = connection?.reconnectDeleteSent == true && self.autoConnectButton.state == .off
                self.controlResult.stringValue = message + (paused ? "；自动连接 SPP 已关闭，需手动勾选恢复" : "")
                self.updateControls()
            }
            connection.buttonEvent = { [weak self] event in self?.buttonMonitor.receive(event) }
            keyTestCounts = [:]
            keyTestResult.stringValue = "04/68 独立事件：电源 0 · 录音 0 · 连接 0"
            connection.keyTestEvent = { [weak self] event in
                guard let self else { return }
                self.keyTestCounts[event.button, default: 0] += 1
                let name = event.button == .power ? "电源键" : event.button == .record ? "录音键" : "连接键"
                self.keyTestResult.stringValue = "04/68：电源 \(self.keyTestCounts[.power, default: 0]) · 录音 \(self.keyTestCounts[.record, default: 0]) · 连接 \(self.keyTestCounts[.link, default: 0]) · 最近 \(name) #\(event.sequence)"
                self.keyTestResult.textColor = .controlAccentColor
            }
            connection.audioSamples = { [weak self] pcm in
                guard let self, self.player?.isPlaying != true else { return }
                self.signalView.append(pcm)
            }
            connection.update = { [weak self] text, seconds, level, presses in
                guard let self else { return }
                if self.player?.isPlaying != true { self.status.stringValue = text }
                self.metrics.stringValue = String(format: "本段 %.3f 秒 · 本连接连接键候选事件 %d 次", seconds, presses)
                self.updateControls()
            }
            connection.recordingComplete = { [weak self] url, message in
                guard let self else { return }
                if let url { self.setRecording(url) }
                self.status.stringValue = message
                self.updateControls()
            }
            connection.unexpectedStop = { [weak self] in
                guard let self else { return }
                self.autoConnectButton.state = .off
                UserDefaults.standard.set(false, forKey: "autoSPP")
            }
            connection.complete = { [weak self] endedSession, message, needsRecovery in
                guard let self, self.session === endedSession else { return }
                self.vibrationTest?.cancel()
                self.denoiseTest?.cancel()
                self.keyTestOperation?.cancel()
                if endedSession.keyTestMayBeActive { self.keyTestResult.stringValue += " · 连接中断，模式状态未确认" }
                self.session = nil
                if endedSession.endedByLinkLoss { self.autoPolicy.linkDisconnected() }
                if needsRecovery { self.captureBlocked = true; self.unresolvedSessions.append(endedSession) }
                if self.player?.isPlaying != true { self.signalView.end() }
                self.buttonMonitor.end(); self.status.stringValue = message
                self.updateControls(); self.finishPendingTermination()
            }
            do { try connection.start() } catch { connection.stop(error.localizedDescription) }
            updateControls()
        } catch { show(error.localizedDescription); updateControls() }
    }
    @objc func disconnectSPP() {
        guard keyTestOperation == nil, denoiseTest == nil, session?.keyTestMayBeActive != true else { return }
        autoConnectButton.state = .off; autoConnectChanged()
        stopPlayback()
        session?.stop("用户断开 SPP")
        updateControls()
    }
    @objc func setKeyTest(_ sender: NSButton) {
        guard keyTestOperation == nil, denoiseTest == nil, vibrationTest == nil, let session, !session.isRecording else { return }
        let test = KeyTestOperation(session: session, enabled: sender.tag == 1) { [weak self] _, message in
            guard let self else { return }
            self.keyTestOperation = nil
            self.controlResult.stringValue = message
            self.updateControls()
        }
        keyTestOperation = test; test.start(); updateControls()
    }
    @objc func setDenoise(_ sender: NSButton) {
        guard denoiseTest == nil, keyTestOperation == nil, vibrationTest == nil,
              let session, session.canQuery, !session.isRecording else { return }
        let test = DenoiseTest(session: session, enabled: sender.tag == 1) { [weak self] message in
            guard let self else { return }
            self.denoiseTest = nil
            self.controlResult.stringValue = message
            self.updateControls()
        }
        denoiseTest = test; test.start(); updateControls()
    }
    @objc func setVibration(_ sender: NSButton) {
        guard denoiseTest == nil, vibrationTest == nil, let session, session.canQuery, !session.isRecording else { return }
        let test = VibrationTest(session: session, enabled: sender.tag == 1) { [weak self] message in
            guard let self else { return }
            self.vibrationTest = nil
            self.controlResult.stringValue = message
            self.updateControls()
        }
        vibrationTest = test; test.start(); updateControls()
    }
    @objc func sendControlQuery(_ sender: NSButton) {
        guard MicControlCommand.allCases.indices.contains(sender.tag) else { return }
        do { try session?.sendQuery(MicControlCommand.allCases[sender.tag]) }
        catch { controlResult.stringValue = error.localizedDescription }
        updateControls()
    }
    @objc func startCapture() {
        guard let session, session.canRecord, !session.isRecording else { return }
        stopPlayback()
        do { try session.startRecording(output: newRecording(), duration: [10.0,30,60][durationPicker.indexOfSelectedItem]) }
        catch { show(error.localizedDescription) }
        updateControls()
    }
    @objc func stopCapture() {
        session?.stopRecording("用户停止录音")
        updateControls()
    }
    @objc func importSPP() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择已有 SPP 原始数据（例如 received.bin）；不会连接蓝牙。"
        panel.beginSheetModal(for: window) { [weak self] result in if result == .OK, let url = panel.url { self?.importFile(url) } }
    }
    func importFile(_ input: URL) {
        guard session == nil, !importing else { return }
        stopPlayback()
        do {
            let output = try newRecording()
            importing = true; status.stringValue = "正在离线解码；未打开蓝牙通道…"; updateControls()
            DispatchQueue.main.asyncAfter(deadline: .now()+8) { [weak self] in
                guard let self, self.importing else { return }
                self.status.stringValue = "正在读取文件或解码。若 macOS 弹出文件访问提示，请先处理；恢复说明仍可打开。"
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try decodeCapture(input: input, output: output) }
                DispatchQueue.main.async {
                    guard let self else { return }; self.importing = false
                    switch result {
                    case .success(let summary):
                        self.setRecording(output); self.status.stringValue = "离线验证完成：\(summary.frames) 帧 · 48 kHz / 单声道 / PCM16"
                        self.metrics.stringValue = String(format: "%.3f 秒 · 无蓝牙连接", summary.seconds); self.signalView.end()
                    case .failure(let error): self.show(error.localizedDescription)
                    }
                    self.updateControls()
                    self.finishPendingTermination()
                }
            }
        } catch { show(error.localizedDescription) }
    }
    func setRecording(_ url: URL) { latest = url; resultLabel.stringValue = url.path }
    @objc func play() {
        if player?.isPlaying == true { stopPlayback(); return }
        guard let latest, session?.isRecording != true, session?.isClosing != true else { return }
        do {
            try AudioRoutes.checkPlaybackOutput()
            playbackFile = try AVAudioFile(forReading: latest, commonFormat: .pcmFormatFloat32, interleaved: false)
            player = try AVAudioPlayer(contentsOf: latest); player?.delegate = self
            guard player?.play() == true else { throw StreamError.invalid("无法开始播放") }
            signalView.begin(playback: true)
            playbackTimer = Timer(timeInterval: 1.0/30, repeats: true) { [weak self] _ in self?.updatePlaybackWaveform() }
            RunLoop.main.add(playbackTimer!, forMode: .common)
            playButton.title = "停止播放"; status.stringValue = "通过当前非 DJI 系统输出播放；音量由系统控制。"
        } catch { show(error.localizedDescription) }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stopPlayback() }
    @objc func reveal() { if let latest { NSWorkspace.shared.activateFileViewerSelecting([latest]) } }
    func show(_ text: String) { status.stringValue = text }
    @objc func recovery() {
        let text = (Bundle.main.url(forResource: "RECOVERY", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "停止 SPP 采集并退出 App，关闭 Mic 2。若普通收音仍异常，在系统蓝牙设置忽略 Mic 2 后重新配对；详情见项目 docs/RECOVERY.md。"
        if let recoveryWindow { recoveryWindow.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        recoveryWindow = panel
        panel.title = "恢复普通蓝牙收音"; panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: panel.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds); view.isEditable = false; view.isSelectable = true
        view.textContainerInset = NSSize(width: 20, height: 20); view.font = .systemFont(ofSize: 14)
        view.autoresizingMask = [.width]; view.isVerticallyResizable = true; view.textContainer?.widthTracksTextView = true; view.string = text
        scroll.documentView = view; panel.contentView!.addSubview(scroll); panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
    private func finishPendingTermination() {
        guard terminating else { return }
        terminating = false
        NSApp.reply(toApplicationShouldTerminate: !captureBlocked)
        if captureBlocked {
            status.stringValue += "。上次会话收尾尚未确认，请先关闭 Mic 2 后再退出。"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if denoiseTest != nil {
            controlResult.stringValue = "降噪设置正在回读，请稍候再退出"
            return .terminateCancel
        }
        if keyTestOperation != nil || session?.keyTestMayBeActive == true {
            controlResult.stringValue = "请先点击「退出按键测试」，收到应答后即可退出 Demo"
            window.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        stopPlayback()
        if session != nil || importing { terminating = true; session?.stop("App 退出"); return .terminateLater }
        if captureBlocked {
            let alert = NSAlert()
            alert.messageText = "会话收尾尚未确认"
            alert.informativeText = "请先关闭 Mic 2。退出后无法继续处理迟到的通道回调，也不代表普通蓝牙收音已恢复。临时音频路由保护已结束。"
            alert.addButton(withTitle: "返回")
            alert.addButton(withTitle: "已关闭 Mic 2，退出")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
