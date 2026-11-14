import AppKit
import AVFoundation
import Combine
import CoreAudio
import IOBluetooth
import ServiceManagement
import UniformTypeIdentifiers
import Mini2Protocol
import MicLinkCore
import MicBridgeSupport

enum BridgePage: String, CaseIterable {
    case device = "设备与录音", settings = "设置", models = "兼容设备", diagnostics = "高级诊断"
    var symbol: String {
        switch self { case .device: return "antenna.radiowaves.left.and.right"
        case .settings: return "slider.horizontal.3"
        case .models: return "mic.and.signal.meter"; case .diagnostics: return "terminal" }
    }
}
struct BridgeDevice: Identifiable {
    let device: IOBluetoothDevice
    let id: String
    let name: String
    let model: MicModel
}

final class BridgeController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var page: BridgePage = .device
    @Published var devices: [BridgeDevice] = []
    @Published var selectedID = "" { didSet {
        buttonShortcuts.select(selectedID)
        hotkeyEnabled = defaults.object(forKey: "hotkeyMode.v2." + selectedID) as? Bool ?? true
        if oldValue != selectedID { batteryPercent = nil; mini2BatteryLevel = nil; nextBatteryRead = 0; sppBatteryReceived = false }
    } }
    @Published var status = "选择已配对的发射器，开始接收声音。"
    @Published var controlStatus = ""
    @Published var phase: ConnectionPhase = .noDevice
    @Published var recovery = RecoveryObservation()
    @Published var audioInputAvailable = false
    @Published var audioActivity = false
    @Published var hfpEndpointAvailable = false
    @Published var bluetoothLogStatus = "蓝牙日志尚未开始监听"
    @Published var bluetoothMode = BluetoothModeEvidence()
    private let bluetoothLogs = BluetoothLogObserver()
    private var bluetoothLogReadable = false
    @Published var audioObservationError: String?
    @Published var stateHistory: [String] = []
    @Published var recoverySeconds = 0
    private var lastAudioAt: TimeInterval?
    private var stateLog: URL?
    private var lastStateKey = ""
    @Published var refreshing = false
    @Published var active = false
    @Published var ready = false
    @Published var closing = false
    @Published private(set) var exitPending = false
    @Published var exitStatus = ""
    @Published var exitConfirmed = false
    @Published var systemMicAvailable = false
    @Published var systemMicEnabled = false
    private var systemMicStartAttempted = false
    @Published private(set) var systemMicIsDefault = false
    @Published private(set) var systemMicName = "MicBridge Audio"
    @Published var systemMicStatus = "请运行 MicBridge 安装包以安装音频组件。"
    @Published var systemMicMetrics = ""
    private var systemMic: SystemMicrophone?
    private var nextVirtualDeviceCheck: TimeInterval = 0
    private var exitPolicy = SPPExitPolicy()
    private var versionQueryAttempted = false
    @Published var recording = false
    @Published var hfpRecording = false
    @Published var hfpPreparing = false
    @Published var hfpTestStatus = ""
    @Published var hfpTestFile: URL?
    private var hfpTest: HFPTestRecorder?
    private var hfpRequest = UUID()
    private var lastHFPTestAudio: TimeInterval?
    @Published var canQuery = false
    @Published var deleted = false
    @Published var captureBlocked = false
    @Published var bluetoothConnected = false
    @Published var seconds: Double = 0
    @Published var presses = 0
    @Published var firmware = "-"
    @Published private(set) var readingMini2Firmware = false
    private var mini2FirmwareAttempts = Set<String>()
    private lazy var mini2FirmwareReader: Mini2FirmwareReader = {
        let reader = Mini2FirmwareReader()
        reader.changed = { [weak self] busy, message in
            self?.readingMini2Firmware = busy
            if !message.isEmpty { self?.status = message }
        }
        return reader
    }()
    private func mini2FirmwareCacheKey(_ id: String) -> String? {
        Mini2FirmwareIdentity.addressKey(id).map { "mini2Firmware.v1." + $0 }
    }
    private func cachedMini2Firmware(_ id: String) -> Mini2FirmwareIdentity? {
        guard let key = mini2FirmwareCacheKey(id), let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Mini2FirmwareIdentity.self, from: data)
    }
    var firmwareHint: String {
        if model == .mini2, let cached = cachedMini2Firmware(selectedID) {
            return "BLE 读取并缓存于 \(cached.readAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "设备固件版本"
    }
    private var controlFirmwareSupported = false
    @Published private(set) var mini2Denoise: Bool?
    var hotkeyActive: Bool { model == .mini2 ? hotkeyEnabled && phase == .streaming : keyMode.enabled == true }
    @Published private(set) var denoise = Mic2DenoiseState()
    @Published private(set) var keyMode = Mic2KeyModeState()
    @Published private(set) var hotkeyEnabled = true
    private var denoiseReadAttempted = false
    private var keyModeAttempted = false
    private var localClosePending = false
    private var buttonExitAttempted = false
    private var buttonExitDeadline: TimeInterval = 0
    private var acknowledgedExitStarted = false
    private var controlsBusy: Bool { denoise.busy || keyMode.busy }
    var canChangeHotkey: Bool {
        !preview && selected?.model.adapter != nil && !exitPending && !closing && !terminating
            && !controlsBusy && (model == .mini2 || session == nil || controlFirmwareSupported)
    }
    var hotkeyStatus: String {
        if model == .mini2 { return hotkeyEnabled ? "连接键单击 / 电源键双击 · 保留原按键功能" : "快捷键发送已暂停" }
        if let error = keyMode.error { return error }
        if keyMode.busy { return "正在切换…" }
        if keyMode.enabled == true { return "短按触发快捷键 · 长按电源仍可关机" }
        if session == nil { return hotkeyEnabled ? "连接后自动启用" : "保留原按键功能" }
        if !controlFirmwareSupported { return "当前固件不支持热键模式" }
        return keyMode.enabled == true ? "短按触发快捷键 · 长按电源仍可关机" : "保留原按键功能"
    }
    func setHotkey(_ enabled: Bool) {
        guard canChangeHotkey else { return }
        hotkeyEnabled = enabled
        defaults.set(enabled, forKey: "hotkeyMode.v2." + selectedID)
        keyModeAttempted = false
        buttonShortcuts.beginSession()
        driveControlActions(); sync()
    }
    var canChangeDenoise: Bool {
        !preview && model == .mic2 && phase == .streaming && !exitPending && !closing && !terminating
            && session?.canQuery == true && denoise.enabled != nil && !controlsBusy && controlFirmwareSupported
    }
    func setDenoise(_ enabled: Bool) {
        guard canChangeDenoise else { return }
        denoise.setEnabled(enabled, now: uptime); driveControlActions(); sync()
    }
    func readDenoise() {
        guard !preview, model == .mic2, !exitPending, !closing, !terminating, session?.canQuery == true, !controlsBusy else { return }
        denoiseReadAttempted = true; denoise.read(now: uptime); driveControlActions(); sync()
    }
    @Published var batteryPercent: Int?
    @Published private(set) var mini2BatteryLevel: Mini2BatteryLevel?
    private var nextBatteryRead: TimeInterval = 0
    private var sppBatteryReceived = false
    private var nextSPPBatteryQuery: TimeInterval = 0
    private let sppBatteryQueryInterval: TimeInterval = 120
    private var sppBatteryQueryFailed = false
    @Published private(set) var controlHealth = ""
    @Published var files: [URL] = []
    @Published var playing: URL?
    @Published var importing = false
    @Published var launchEnabled = false
    @Published var launchNeedsApproval = false
    @Published var launchStatus = ""
    @Published var autoSPP: Bool { didSet { preferences.autoSPP = autoSPP; autoPolicy.linkDisconnected(); if !autoSPP { resumePolicy.cancel() } } }
    @Published var showWindow: Bool { didSet { preferences.showWindow = showWindow } }
    @Published var duration = 3600.0
    @Published var recordingFolder: URL
    let preview: Bool
    let preferences: BridgePreferences
    let buttonShortcuts: ButtonShortcuts
    let signalView = SignalView(frame: .zero)
    var showWindowAction: (() -> Void)?
    var finishedTermination: ((Bool) -> Void)?
    private(set) var session: MicSession?
    private var unresolved: [MicSession] = []
    private var watchedDevice: IOBluetoothDevice?
    private var watchedHandle: BluetoothConnectionHandle?
    private var disconnectNotice: IOBluetoothUserNotification?
    private var monitor: Timer?
    private var autoPolicy = AutoSPPPolicy()
    private var resumePolicy = SPPResumePolicy()
    private var player: AVAudioPlayer?
    private var terminating = false
    private var terminationRestoresHFP = false
    private var firmwareByAddress: [String: String] = [:]
    private let defaults: UserDefaults

    init(preview: Bool = false) {
        self.preview = preview
        let defaults = preview ? UserDefaults(suiteName: "org.dji-mic-rxless.micbridge.preview")! : .standard
        self.defaults = defaults
        buttonShortcuts = ButtonShortcuts(defaults: defaults, preview: preview)
        preferences = BridgePreferences(defaults: defaults)
        autoSPP = preview ? false : preferences.autoSPP
        showWindow = preferences.showWindow
        recordingFolder = preview ? URL(fileURLWithPath: "/Example/Recordings", isDirectory: true)
            : defaults.url(forKey: "recordingFolder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/MicBridge", isDirectory: true)
        super.init()
        updateLaunchStatus()
        if preview { status = "界面预览 · 未访问蓝牙或音频设备"; return }
        reloadFiles()
        refreshSystemMicrophone()
        bluetoothLogs.onStatus = { [weak self] status, readable in
            guard let self else { return }
            self.bluetoothLogStatus = status; self.bluetoothLogReadable = readable
            if !readable { self.bluetoothMode.reset(since: Date()) }
            self.updateConnectionState()
        }
        bluetoothLogs.onEvent = { [weak self] event, date in
            guard let self, !self.preview, self.bluetoothConnected,
                  self.bluetoothMode.accept(event, at: date, now: Date()) else { return }
            self.observeSystemAudio(); self.updateConnectionState()
        }
        monitor = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.monitorConnection() }
        RunLoop.main.add(monitor!, forMode: .common)
    }
    var selected: BridgeDevice? { devices.first { $0.id == selectedID } }
    var model: MicModel { selected?.model ?? (preview ? .mic2 : .unknown) }
    var name: String { selected?.name ?? (preview ? "DJI-MIC2-EXAMPLE · 界面预览" : "尚未选择发射器") }
    var canConnect: Bool { !preview && selected?.model.adapter != nil && !active && !captureBlocked && !refreshing && !importing && !hfpBusy && bluetoothConnected && !readingMini2Firmware && !terminating && !exitPending }
    var hfpBusy: Bool { hfpRecording || hfpPreparing }
    var canTestHFP: Bool { !preview && bluetoothConnected && audioInputAvailable && selected != nil
        && preferences.ordinaryAudioRestored(for: selectedID)
        && !active && !closing && !captureBlocked && !importing && !hfpBusy && !demoRunning && !readingMini2Firmware }
    var canToggleRecording: Bool { !preview && !exitPending && (hfpBusy || (ready && (recording || phase == .streaming)) || canTestHFP) }
    var recordingButtonTitle: String { hfpPreparing ? "取消测试" : hfpRecording ? "停止测试" : recording ? "停止录音" : active ? "开始录音" : "测试 HFP 录音" }
    var recordingHint: String {
        if hfpPreparing { return "等待麦克风授权，允许后开始测试。" }
        if hfpRecording { return "HFP 测试中 · 最长 2 分钟，停止后可直接试听。" }
        if !active && !hfpTestStatus.isEmpty { return hfpTestStatus }
        if captureBlocked { return "录音暂不可用。" }
        if canTestHFP { return "点击测试普通蓝牙收音；测试时暂停自动 SPP，最长 2 分钟。" }
        return recording ? "正在保存声音。" : phase == .streaming ? "点击开始录音，保存这段声音。" : "等待音频输入，或连接 SPP 开始收音。"
    }
    var elapsed: String { String(format: "%02d:%02d.%01d", Int(seconds)/60, Int(seconds)%60, Int(seconds*10)%10) }
    private var showSPPExit: Bool { exitConfirmed && !active && !hfpBusy && bluetoothConnected }
    var connectionLabel: String { exitPolicy.failed && active ? "未能断开 SPP" : showSPPExit ? "SPP 已断开" : phase.title }
    var connectionDetail: String {
        if exitPolicy.failed && active { return "退出指令未完成，详情请查看高级诊断。" }
        if exitConfirmed && !active && !hfpBusy { return "建议将发射器关机再开机，再使用普通蓝牙录音，恢复更稳妥。" }
        if phase == .closeUnconfirmed { return "连接未能正常结束，详情请查看高级诊断。" }
        return phase.detail
    }
    var connectionWarning: Bool { !showSPPExit && phase.warning }
    var connectionSymbol: String { showSPPExit ? "checkmark.circle" : phase.symbol }
    var stateLogURL: URL? { stateLog }
    var recoveryDescription: String? {
        guard recovery.started != nil else { return nil }
        if recoverySeconds < 180 {
            return "退出后前 3 分钟 · 断连 \(recovery.disconnects) 次 · 已观察 \(recoverySeconds) 秒"
        }
        return "退出后前 3 分钟断连 \(recovery.disconnects) 次 · 之后观察到 \(recovery.laterDisconnects) 次"
    }
    var canEnableSystemMicrophone: Bool {
        !preview && systemMicAvailable && phase == .streaming && !exitPending && !closing && !hfpBusy
    }
    func refreshSystemMicrophone() {
        guard !preview else { return }
        refreshSystemMicrophoneDefault()
        guard systemMic == nil else { return }
        do {
            let device = try VirtualAudioDevice.find()
            let available = device != nil
            let name = device?.name ?? "MicBridge Audio"
            if available != systemMicAvailable || name != systemMicName {
                systemMicName = name
                systemMicStartAttempted = false
                systemMicStatus = available ? "连接 SPP 后自动输出到 \(systemMicName)。" : "请运行 MicBridge 安装包以安装音频组件。"
            }
            systemMicAvailable = available
        } catch { systemMicAvailable = false; systemMicStatus = error.localizedDescription }
    }
    private func refreshSystemMicrophoneDefault() {
        let reader = AudioRoutes(target: "DJI")
        let current = try? reader.integer(reader.system, kAudioHardwarePropertyDefaultInputDevice)
        let destination = systemMic?.device.id ?? (try? VirtualAudioDevice.find())?.id
        systemMicIsDefault = destination != nil && current == destination
        if systemMicEnabled && systemMicStatus.hasPrefix("已") {
            systemMicStatus = systemMicIsDefault ? "已设为系统输入 · \(systemMicName)" : "已启用 · 在其他软件中选择 \(systemMicName)。"
        }
    }
    private func startSystemMicrophoneIfReady() {
        guard !systemMicStartAttempted, canEnableSystemMicrophone else { return }
        // Once per SPP session, including a reused bridge after TX power loss.
        systemMicStartAttempted = true
        if systemMic == nil {
            do {
                guard let device = try VirtualAudioDevice.find() else { throw StreamError.invalid("未找到 MicBridge Audio，请运行安装包安装音频组件。") }
                systemMicName = device.name
                let output = try SystemMicrophone(device: device)
                output.failed = { [weak self] message in
                    self?.stopSystemMicrophone(); self?.systemMicStatus = message
                }
                output.updated = { [weak self] text in self?.systemMicMetrics = text }
                systemMic = output
                try output.start()
                systemMicEnabled = true; systemMicStatus = "已启用 · 在其他软件中选择 \(systemMicName)。"
            } catch { stopSystemMicrophone(); systemMicStatus = error.localizedDescription; return }
        }
        // A default-route failure must not stop a working audio bridge.
        useSystemMicrophoneAsDefault()
    }
    private func stopSystemMicrophone() {
        systemMic?.stop(); systemMic = nil; systemMicEnabled = false; systemMicMetrics = ""
        systemMicStatus = systemMicAvailable ? "连接 SPP 后自动输出到 \(systemMicName)。" : "请运行 MicBridge 安装包以安装音频组件。"
    }
    func useSystemMicrophoneAsDefault() {
        guard systemMicEnabled else { return }
        do { try systemMic?.makeDefaultInput(); refreshSystemMicrophoneDefault() }
        catch { systemMicStatus = error.localizedDescription }
    }
    func openSystemMicrophoneSetup() {
        let adjacent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("MicBridge-Installer.pkg")
        if FileManager.default.fileExists(atPath: adjacent.path) { NSWorkspace.shared.open(adjacent); return }
        let panel = NSOpenPanel()
        panel.title = "打开 MicBridge 安装包"
        panel.message = "安装包会同时安装 App 和 MicBridge Audio。"
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg") ?? .package]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { NSWorkspace.shared.open(url) }
    }
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func beginRecovery() {
        recovery.begin(now: uptime, connected: bluetoothConnected)
    }
    /// Property reads only: never opens a HAL stream or changes a route.
    private func observeSystemAudio() {
        guard !preview else { return }
        audioInputAvailable = false; audioActivity = false; hfpEndpointAvailable = false; audioObservationError = nil
        guard bluetoothConnected, !selectedID.isEmpty else { return }
        do {
            let reader = AudioRoutes(target: selectedID)
            let targets = try reader.devices().filter { try reader.isTarget($0) }
            for device in targets where try reader.integer(device, kAudioDevicePropertyDeviceIsAlive) == 1 {
                if reader.hasStream(device, input: true) {
                    audioInputAvailable = true
                    if let uid = try? reader.string(device, kAudioDevicePropertyDeviceUID),
                       (try? reader.integer(device, kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeBluetooth,
                       BluetoothModeEvidence.isHFPEndpoint(uid: uid, target: selectedID) { hfpEndpointAvailable = true }
                }
                if try reader.integer(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 { audioActivity = true }
            }
        } catch { audioInputAvailable = false; audioActivity = false; hfpEndpointAvailable = false; audioObservationError = error.localizedDescription }
    }
    private func updateConnectionState() {
        guard !preview else { return }
        bluetoothMode.reconcile(inputAvailable: audioInputAvailable, audioActive: audioActivity, now: Date())
        var evidence = ConnectionEvidence()
        evidence.selected = selected != nil; evidence.supported = selected?.model.adapter != nil
        evidence.bluetooth = bluetoothConnected; evidence.session = active; evidence.closing = closing
        evidence.sppReady = ready
        evidence.hfpCapture = hfpRecording
        evidence.hfpRecentAudio = lastHFPTestAudio.map { uptime - $0 <= 3 } ?? false
        evidence.hfpIdentified = hfpEndpointAvailable || (bluetoothLogReadable && bluetoothMode.hfpCreated)
        evidence.hfpVoiceConnected = bluetoothLogReadable && bluetoothMode.voiceConnected
        evidence.receivedAudio = lastAudioAt != nil
        evidence.recentAudio = lastAudioAt.map { uptime - $0 <= 3 } ?? false
        evidence.closeUnresolved = captureBlocked
        evidence.audioReadable = audioObservationError == nil
        evidence.inputAvailable = audioInputAvailable; evidence.systemAudioActive = audioActivity
        recovery.observe(connected: bluetoothConnected, inputAvailable: audioInputAvailable && !active && !closing && !captureBlocked, now: uptime)
        recoverySeconds = min(180, Int(recovery.elapsed(at: uptime)))
        let next = ConnectionPhase.resolve(evidence, recovery: recovery, now: uptime)
        if phase != next { phase = next }
        let key = "\(selectedID)|\(next.rawValue)|\(recovery.disconnects)|\(recovery.laterDisconnects)|\(bluetoothMode.lastEventAt?.timeIntervalSince1970 ?? 0)|\(bluetoothLogReadable)|\(hfpEndpointAvailable)"
        guard key != lastStateKey else { return }; lastStateKey = key
        let stamp = ISO8601DateFormatter().string(from: Date())
        stateHistory.append("\(stamp) · \(next.title)" + (recovery.started == nil ? "" : " · 前 3 分钟断连 \(recovery.disconnects) 次 · 之后 \(recovery.laterDisconnects) 次"))
        if stateHistory.count > 200 { stateHistory.removeFirst() }
        do {
            if stateLog == nil {
                let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MicBridge/Connections", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = folder.appendingPathComponent("States-\(UUID()).jsonl")
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                stateLog = url
            }
            let row: [String: Any] = ["time": stamp, "device": selectedID, "phase": next.rawValue, "bluetooth": bluetoothConnected,
                "spp_session": active, "auto_spp": autoSPP, "resume_spp_pending": resumePolicy.shouldResume(target: selectedID), "recent_decoded_audio": evidence.recentAudio, "input_available": audioInputAvailable,
                "system_audio_active": audioActivity, "close_unresolved": captureBlocked, "disconnects": recovery.disconnects,
                "later_disconnects": recovery.laterDisconnects,
                "hfp_endpoint_identified": hfpEndpointAvailable, "bluetooth_log_readable": bluetoothLogReadable,
                "bluetooth_log_event": bluetoothMode.lastEvent?.rawValue ?? "",
                "bluetooth_log_event_time": bluetoothMode.lastEventAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "hfp_voice_connected_observed": bluetoothMode.voiceConnected,
                "recovery_elapsed_seconds": Int(recovery.elapsed(at: uptime)),
                "recovery_seconds": recoverySeconds, "audio_error": audioObservationError ?? ""]
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
            let file = try FileHandle(forWritingTo: stateLog!); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        } catch { /* Status observation must not change the transport on a log failure. */ }
    }
    func previewState(_ state: ConnectionPhase) {
        guard preview else { return }
        phase = state
        if state == .streaming {
            let config: [UInt8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xd0,0,12,0,0,0xd0,0,12,0,0]
            denoise.read(now: 0); denoise.sent(); denoise.receive(.audioConfiguration, result: .success(config))
            keyMode.setEnabled(true, now: 0); keyMode.sent(); keyMode.receive(.audioConfiguration, result: .success(config))
            keyMode.sent(); keyMode.receive(.keyTestOn, result: .success([0,0x43,1,1]))
        } else { denoise = Mic2DenoiseState(); keyMode = Mic2KeyModeState() }
        status = "离线状态示例 · 不代表当前设备现场"
        stateHistory = ["离线预览 · \(state.title)"]
    }
    var modeEvidenceDetail: String {
        if preview { return "离线预览，不读取蓝牙日志或系统音频。" }
        var parts = [hfpEndpointAvailable ? "CoreAudio：已识别当前设备的 HFP 输入端点" : audioInputAvailable ? "CoreAudio：当前设备输入可用，协议未确认" : "CoreAudio：尚无可用输入"]
        parts.append(bluetoothLogStatus)
        if let event = bluetoothMode.lastEvent, let date = bluetoothMode.lastEventAt {
            let names: [BluetoothModeEvent: String] = [.hfpCreated: "HFP 设备创建", .voiceConnected: "语音链路连接", .voiceDisconnected: "语音链路断开", .aclConnected: "蓝牙连接", .aclDisconnected: "蓝牙断开"]
            parts.append("最近证据：\(names[event] ?? event.rawValue) · \(date.formatted(date: .omitted, time: .standard))")
        }
        parts.append("仅显示当前设备的有效连接记录。")
        return parts.joined(separator: "\n")
    }
    func stopModeObservation() { bluetoothLogs.stop() }
    var demoRunning: Bool { ["org.dji-mic-rxless.demo", "org.micbridge.mini2-demo"].contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } }
    func sync() {
        active = session != nil; ready = session?.canRecord == true; closing = session?.isClosing == true
        recording = session?.isRecording == true || hfpRecording; canQuery = model == .mic2 && session?.canQuery == true
        canQuery = canQuery && !exitPending && !terminating && !controlsBusy
        deleted = session?.reconnectDeleteSent == true
        if closing { beginRecovery() }
        updateConnectionState()
    }
    func refresh() {
        guard !preview, !refreshing, session == nil, !importing, !captureBlocked, !hfpBusy, !readingMini2Firmware else { return }
        refreshing = true; status = "正在读取已配对的 DJI Mic…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter {
                ($0.name ?? "").uppercased().filter { $0.isLetter || $0.isNumber }.hasPrefix("DJIMIC")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.devices = found.compactMap { d in
                    guard let id = d.addressString else { return nil }
                    return BridgeDevice(device: d, id: id, name: d.name ?? "DJI Mic", model: .identify(d.name ?? ""))
                }
                self.refreshing = false
                let saved = self.defaults.string(forKey: "selectedDevice") ?? self.selectedID
                if self.devices.contains(where: { $0.id == saved }) { self.select(saved) }
                else if self.devices.count == 1 { self.select(self.devices[0].id) }
                else { self.select(""); self.status = self.devices.isEmpty ? "未找到已配对设备。请先在 macOS 蓝牙中配对发射器，再刷新。" : "请选择发射器。" }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+10) { [weak self] in
            guard let self, self.refreshing else { return }; self.status = "蓝牙服务尚未返回；仍可使用本地录音文件。"
        }
    }
    func select(_ id: String) {
        guard session == nil, !captureBlocked, !hfpBusy, !readingMini2Firmware else { return }
        disconnectNotice?.unregister(); disconnectNotice = nil
        if selectedID != id { stopSystemMicrophone(); exitConfirmed = false; resumePolicy.cancel(); recovery = RecoveryObservation(); lastAudioAt = nil }
        let changedDevice = selectedID != id
        selectedID = id; watchedDevice = selected?.device; watchedHandle = nil; autoPolicy.linkDisconnected()
        bluetoothConnected = watchedDevice?.isConnected() == true
        defaults.set(id, forKey: "selectedDevice")
        firmware = (model == .mini2 ? cachedMini2Firmware(id)?.version : firmwareByAddress[id]) ?? "-"
        if changedDevice && !preview {
            hfpTestFile = nil; hfpTestStatus = ""
            audioInputAvailable = false; audioActivity = false; hfpEndpointAvailable = false; audioObservationError = nil
            bluetoothMode.reset(since: Date())
            bluetoothLogs.start(target: id)
        }
        status = selected?.model.compatibility ?? "请选择发射器。"
        observeSystemAudio(); updateConnectionState()
    }
    private func handleBluetoothLoss() {
        if readingMini2Firmware { mini2FirmwareReader.cancel() }
        controlFirmwareSupported = false
        denoise = Mic2DenoiseState(); keyMode = Mic2KeyModeState()
        systemMic?.reset()
        if systemMicEnabled { systemMicStatus = "等待发射器重新连接，当前输出静音。" }
        if hfpBusy { stopHFPTest(reason: "蓝牙已断开，HFP 测试已停止；恢复后可重新测试。") }
        bluetoothMode.reset(since: Date())
        batteryPercent = nil; mini2BatteryLevel = nil; nextBatteryRead = 0; sppBatteryReceived = false
        bluetoothConnected = false; recovery.observe(connected: false, now: uptime)
        audioInputAvailable = false; audioActivity = false; hfpEndpointAvailable = false; audioObservationError = nil
        resumePolicy.linkLost(target: selectedID)
        autoPolicy.linkDisconnected(); watchedHandle = nil
        disconnectNotice?.unregister(); disconnectNotice = nil
        captureBlocked = false
        let old = unresolved; unresolved.removeAll(); old.forEach { $0.retireForLinkLoss() }
        session?.retireForLinkLoss()
        // A spontaneous RFCOMM close can precede the ACL loss. Only a retained
        // working-session intent may clear that generic close observation.
        if resumePolicy.shouldResume(target: selectedID), !captureBlocked { recovery = RecoveryObservation() }
        if session == nil { status = "蓝牙已断开，等待发射器重新连接。" }
        sync()
    }
    @objc private func bluetoothDisconnected(_ notice: IOBluetoothUserNotification!, device: IOBluetoothDevice!) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.bluetoothDisconnected(notice, device: device) }; return }
        guard let notice, disconnectNotice === notice, device?.addressString == watchedDevice?.addressString else { return }
        handleBluetoothLoss()
    }
    private func monitorConnection() {
        if !preview, uptime >= nextVirtualDeviceCheck {
            nextVirtualDeviceCheck = uptime + 2; refreshSystemMicrophone(); buttonShortcuts.refreshPermission()
        }
        guard !preview, !importing, let device = watchedDevice else { return }
        defer { observeSystemAudio(); driveControlActions(); updateConnectionState(); startSystemMicrophoneIfReady() }
        let wasConnected = bluetoothConnected
        bluetoothConnected = device.isConnected()
        guard bluetoothConnected else {
            if wasConnected || watchedHandle != nil || session != nil { handleBluetoothLoss() }
            _ = autoPolicy.shouldConnect(enabled: autoSPP, connected: false, ready: false, busy: false, now: ProcessInfo.processInfo.systemUptime)
            return
        }
        if let previous = watchedHandle, previous != device.connectionHandle { handleBluetoothLoss() }
        bluetoothConnected = device.isConnected()
        if !wasConnected && bluetoothConnected {
            bluetoothMode.reset(since: Date())
            if session == nil && !captureBlocked { status = "蓝牙已重新连接，正在自动检查系统音频状态。" }
        }
        if uptime >= nextBatteryRead {
            nextBatteryRead = uptime + 10
            if !sppBatteryReceived {
                let reported = BluetoothBattery.percent(for: device)
                if batteryPercent != reported { batteryPercent = reported }
            }
        }
        recovery.observe(connected: bluetoothConnected, now: uptime)
        watchedHandle = device.connectionHandle
        if disconnectNotice == nil { disconnectNotice = device.register(forDisconnectNotification: self, selector: #selector(bluetoothDisconnected(_:device:))) }
        let shouldReconnect = autoSPP || resumePolicy.shouldResume(target: selectedID)
        guard !terminating, !exitPending, !hfpBusy, !readingMini2Firmware, recovery.started == nil, session == nil, !captureBlocked, selected?.model.adapter != nil, shouldReconnect, !demoRunning else { return }
        let reader = AudioRoutes(target: selectedID)
        let audioReady: Bool
        do {
            let targets = try reader.devices().filter { try reader.isTarget($0) }
            audioReady = try !targets.isEmpty && targets.allSatisfy { try reader.integer($0, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 }
        } catch { return }
        if autoPolicy.shouldConnect(enabled: shouldReconnect, connected: true, ready: audioReady, busy: false, now: ProcessInfo.processInfo.systemUptime) { connect() }
    }
    private func connectionLog() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MicBridge/Connections", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("Connection-\(UUID()).session.json")
    }
    func connect() {
        guard canConnect, let selected, selected.model.adapter != nil else { return }
        guard !demoRunning else { status = "请先退出 Demo，再由 MicBridge 连接 SPP。"; return }
        if selected.model == .mini2, cachedMini2Firmware(selected.id) == nil,
           mini2FirmwareAttempts.insert(selected.id).inserted {
            mini2FirmwareReader.read(address: selected.id) { [weak self] identity in
                guard let self else { return }
                if let identity, let key = self.mini2FirmwareCacheKey(selected.id),
                   let data = try? JSONEncoder().encode(identity) {
                    self.defaults.set(data, forKey: key)
                    if self.selectedID == selected.id { self.firmware = identity.version }
                }
                guard self.selectedID == selected.id, self.session == nil, !self.terminating else { return }
                self.connect()
            }
            return
        }
        exitPolicy = SPPExitPolicy(); exitPending = false; exitConfirmed = false; exitStatus = ""; versionQueryAttempted = false
        controlFirmwareSupported = false
        mini2Denoise = nil; denoise = Mic2DenoiseState(); denoiseReadAttempted = false
        keyMode = Mic2KeyModeState(); keyModeAttempted = false
        localClosePending = false; buttonExitAttempted = false; acknowledgedExitStarted = false
        resumePolicy.begin(target: selected.id)
        recovery = RecoveryObservation(); lastAudioAt = nil
        autoPolicy.markAttempted(); stopPlayback()
        do {
            let connection = try MicSession(device: selected.device, model: selected.model, eventLog: connectionLog())
            preferences.setOrdinaryAudioRestored(false, for: selected.id)
            session = connection; signalView.begin(); seconds = 0; presses = 0
            sppBatteryReceived = false; controlHealth = "等待 SPP 状态包"
            nextSPPBatteryQuery = 0; sppBatteryQueryFailed = false
            connection.queryCompleted = { [weak self, weak connection] command, result in
                guard let self, let connection, self.session === connection,
                      !connection.isClosing else { return }
                if command == .version {
                    if case let .success(payload) = result, payload.count == 30 {
                        self.controlFirmwareSupported = Array(payload[22..<26]) == [31, 2, 5, 4]
                    } else { self.controlFirmwareSupported = false }
                }
                self.denoise.receive(command, result: result)
                self.keyMode.receive(command, result: result)
                self.driveControlActions(); self.sync()
            }
            connection.batteryUpdate = { [weak self, weak connection] percent in
                guard let self, let connection, self.session === connection else { return }
                self.sppBatteryReceived = true; self.batteryPercent = percent
            }
            connection.mini2Status = { [weak self, weak connection] status in
                guard let self, let connection, self.session === connection else { return }
                if self.mini2Denoise != status.denoise { self.mini2Denoise = status.denoise }
                self.sppBatteryReceived = true
                let level = status.batteryLevel
                if self.mini2BatteryLevel != level { self.mini2BatteryLevel = level }
                if self.batteryPercent != level?.estimatedPercent { self.batteryPercent = level?.estimatedPercent }
            }
            connection.mini2Hotkey = { [weak self, weak connection] event in
                guard let self, let connection, self.session === connection else { return }
                self.buttonShortcuts.receive(event, active: self.hotkeyEnabled && self.active && !self.closing && !self.exitPending && !self.terminating && !self.hfpBusy)
            }
            buttonShortcuts.beginSession()
            systemMicStartAttempted = false
            connection.buttonEvent = { [weak self, weak connection] event in
                guard let self, let connection, self.session === connection,
                      event.button == .power, self.keyMode.enabled == false,
                      !self.exitPending, !self.terminating else { return }
                // Ordinary physical denoise changes refresh the switch, never shortcuts.
                self.denoiseReadAttempted = false
            }
            connection.keyTestEvent = { [weak self, weak connection] event in
                guard let self, let connection, self.session === connection else { return }
                self.buttonShortcuts.receive(event, active: self.hotkeyEnabled && self.keyMode.enabled == true && !self.keyMode.busy && self.active && !self.closing && !self.exitPending && !self.terminating && !self.hfpBusy)
            }
            connection.beforeReconnectDeletion = { [weak self] in
                guard let self else { throw StreamError.invalid("App 已退出，未发送指令") }
                self.preferences.prepareReconnectDeletion(); self.autoSPP = false
            }
            connection.controlResult = { [weak self, weak connection] command, success in
                // Never dispose RFCOMM while the parser is still inside its callback.
                DispatchQueue.main.async {
                    guard let self, let connection, self.session === connection else { return }
                    if command == .deleteSPPReconnect { self.exitPolicy.reply(success: success) }
                    if command == .battery && !success { self.sppBatteryQueryFailed = true }
                    self.driveControlActions()
                }
            }
            connection.controlUpdate = { [weak self] message in
                guard let self else { return }; self.controlStatus = message
                if let range = message.range(of: "TX 固件 ") {
                    let version = String(message[range.upperBound...].prefix(11))
                    if version.range(of: "^\\d{2}\\.\\d{2}\\.\\d{2}\\.\\d{2}$", options: .regularExpression) != nil {
                        self.firmware = version; self.firmwareByAddress[selected.id] = version
                    }
                }
                self.sync()
            }
            connection.audioSamples = { [weak self, weak connection] samples in
                guard !samples.isEmpty, let self, let connection, self.session === connection else { return }
                self.systemMic?.append(samples)
                if self.systemMicEnabled && self.systemMicStatus.hasPrefix("等待发射器") {
                    self.systemMicStatus = "已启用 · 在其他软件中选择 \(self.systemMicName)。"
                }
                self.resumePolicy.audioReceived(target: selected.id)
                self.lastAudioAt = self.uptime; self.signalView.append(samples)
            }
            connection.update = { [weak self] text, seconds, _, presses in
                guard let self else { return }; self.status = text; self.seconds = seconds; self.presses = presses
                if let session = self.session {
                    let health = "控制包 \(session.controlFramesReceived) · 按键状态包 \(session.statusFramesReceived)"
                    if self.controlHealth != health { self.controlHealth = health }
                }
                self.sync()
            }
            connection.recordingComplete = { [weak self] _, text in self?.status = text; self?.reloadFiles(); self?.sync() }
            connection.unexpectedStop = { [weak self] in self?.autoSPP = false }
            connection.complete = { [weak self] ended, text, recovery in
                guard let self, self.session === ended else { return }
                let exitWasAcknowledged = self.exitPolicy.closeAuthorized
                self.controlFirmwareSupported = false
                self.mini2Denoise = nil; self.denoise = Mic2DenoiseState(); self.keyMode = Mic2KeyModeState(); self.localClosePending = false
                self.session = nil; self.exitPending = false; self.exitPolicy = SPPExitPolicy()
                self.sppBatteryReceived = false; self.batteryPercent = nil; self.mini2BatteryLevel = nil; self.nextBatteryRead = 0
                if exitWasAcknowledged {
                    self.preferences.setOrdinaryAudioRestored(true, for: selected.id)
                    self.exitConfirmed = true; self.exitStatus = "SPP 已断开"
                }
                else if ended.endedByLinkLoss { self.exitStatus = "蓝牙已断开；未据此确认 HFP 恢复。" }
                if self.terminating && self.terminationRestoresHFP && !exitWasAcknowledged && !ended.endedByLinkLoss {
                    self.terminating = false
                    self.exitStatus = "通道已异常结束，未完成 12/65 应答确认；本次退出已取消。"
                    self.finishedTermination?(false); self.showWindowAction?()
                }
                if ended.endedByLinkLoss { self.resumePolicy.linkLost(target: selected.id); self.autoPolicy.linkDisconnected() }
                if recovery { self.resumePolicy.cancel(); self.captureBlocked = true; self.unresolved.append(ended) }
                self.systemMic?.reset()
                if !ended.endedByLinkLoss || recovery { self.stopSystemMicrophone() }
                self.signalView.end(); self.status = text; self.sync(); self.finishTermination()
            }
            do { try connection.start() } catch { connection.stop(error.localizedDescription) }
            sync()
        } catch { resumePolicy.cancel(); status = error.localizedDescription; sync() }
    }
    func disconnect() {
        guard session != nil, !closing, !exitPending else { return }
        beginAcknowledgedExit()
    }
    private func beginAcknowledgedExit() {
        guard session != nil else { return }
        autoSPP = false; stopPlayback(); stopSystemMicrophone()
        prepareButtonExit()
        exitPending = true; exitStatus = "等待指令通道就绪，发送 12/65 后再关闭 SPP…"
        acknowledgedExitStarted = false
        // Also used from applicationShouldTerminate: defer callbacks until AppKit
        // has received terminateLater before replying to the termination request.
        DispatchQueue.main.async { [weak self] in self?.driveControlActions() }
        sync()
    }
    private func prepareButtonExit() {
        // Drop unsent work. Any in-flight command completes before keyTestOff.
        denoise = Mic2DenoiseState(); keyMode = Mic2KeyModeState()
        buttonExitAttempted = false; buttonExitDeadline = uptime + 30
    }
    private func restoreButtonsBeforeClosing(_ session: MicSession) -> Bool {
        keyMode.expire(now: uptime)
        if let error = keyMode.error { failButtonExit(error); return false }
        if session.keyTestMayBeActive {
            if !buttonExitAttempted {
                buttonExitAttempted = true
                keyMode.setEnabled(false, now: uptime)
            }
            if let command = keyMode.request, session.canRecoverKeyTest {
                keyMode.sent()
                do { try session.sendQuery(command) }
                catch { keyMode.fail(error.localizedDescription); failButtonExit(error.localizedDescription) }
            }
            if uptime >= buttonExitDeadline { failButtonExit("恢复普通按键超时，请重试退出") }
            return false
        }
        // A query may still be draining; never close underneath a settings write.
        if session.controlIdle { return true }
        if uptime >= buttonExitDeadline { failButtonExit("指令通道忙，请重试退出") }
        return false
    }
    private func failButtonExit(_ message: String) {
        localClosePending = false; keyModeAttempted = true
        failAcknowledgedExit("未恢复普通按键：" + message)
    }
    private func driveControlActions() {
        guard let session else { return }
        if exitPending || localClosePending {
            guard restoreButtonsBeforeClosing(session) else { return }
            if localClosePending {
                localClosePending = false; session.stop("App 退出"); return
            }
            if !acknowledgedExitStarted {
                acknowledgedExitStarted = true; exitPolicy.request(now: uptime)
            }
            switch exitPolicy.advance(canQuery: session.canQuery, alreadySent: session.reconnectDeleteSent, now: uptime) {
            case .none: break
            case .sendCommand:
                exitStatus = "正在等待 12/65 成功回应，SPP 暂时保持连接…"
                do { try session.sendQuery(.deleteSPPReconnect) }
                catch { failAcknowledgedExit(error.localizedDescription) }
            case .closeChannel:
                exitStatus = "已收到 12/65 ACK 00，正在关闭 SPP 通道…"
                beginRecovery(); session.closeAfterAcknowledgedExit(); sync()
            case .fail:
                failAcknowledgedExit("未取得 12/65 成功回应；SPP 保持连接。" + controlStatus)
            }
            return
        }
        guard !terminating, model == .mic2 else { return }
        denoise.expire(now: uptime); keyMode.expire(now: uptime)
        // Once per new SPP session, including automatic power-cycle recovery.
        guard !session.isClosing else { return }
        if keyMode.busy {
            if let command = keyMode.request, (command == .keyTestOff ? session.canRecoverKeyTest : session.canQuery) {
                keyMode.sent()
                do { try session.sendQuery(command) } catch { keyMode.fail(error.localizedDescription) }
            }
            return
        }
        guard session.canQuery else { return }
        if !versionQueryAttempted {
            versionQueryAttempted = true
            do { try session.sendQuery(.version) }
            catch { controlStatus = "自动读取固件失败：" + error.localizedDescription }
            return
        }
        if denoise.busy {
            if let request = denoise.request {
                denoise.sent()
                do { try session.sendQuery(request.command, configuration: request.configuration) }
                catch { denoise.fail(error.localizedDescription) }
            }
            return
        }
        if controlFirmwareSupported && !keyModeAttempted {
            keyModeAttempted = true; keyMode.setEnabled(hotkeyEnabled, now: uptime)
            driveControlActions(); return
        }
        if !denoiseReadAttempted {
            denoiseReadAttempted = true; denoise.read(now: uptime); driveControlActions(); return
        }
        if !sppBatteryQueryFailed, uptime >= nextSPPBatteryQuery {
            nextSPPBatteryQuery = uptime + sppBatteryQueryInterval
            do { try session.sendQuery(.battery) }
            catch { sppBatteryQueryFailed = true }
        }
    }
    private func failAcknowledgedExit(_ message: String) {
        exitPolicy.fail(); exitPending = false
        exitStatus = message; status = message
        if terminating { terminating = false; finishedTermination?(false); showWindowAction?() }
        sync()
    }
    func send(_ command: MicControlCommand) {
        guard [.version, .audioConfiguration, .deviceAddress, .battery].contains(command) else { return }
        guard !preview, !exitPending, !terminating, !controlsBusy, selected?.model.adapter == .mic2SPP else { return }
        if command == .version { versionQueryAttempted = true }
        if command == .battery { nextSPPBatteryQuery = uptime + sppBatteryQueryInterval; sppBatteryQueryFailed = false }
        do { try session?.sendQuery(command) } catch { controlStatus = error.localizedDescription }; sync()
    }
    private func newRecording() throws -> URL {
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return recordingFolder.appendingPathComponent("Mic-\(date)-\(UUID().uuidString.prefix(6)).wav")
    }
    func toggleRecording() {
        guard !preview, !exitPending else { return }
        if hfpBusy { stopHFPTest(); return }
        guard let session else { startHFPTest(); return }
        if session.isRecording { session.stopRecording("用户停止录音") }
        else { guard phase == .streaming else { return }; stopPlayback(); do { try session.startRecording(output: newRecording(), duration: duration) } catch { status = error.localizedDescription } }
        sync()
    }
    private func startHFPTest() {
        guard canTestHFP else { return }
        stopPlayback(); autoSPP = false; stopSystemMicrophone()
        hfpPreparing = true; hfpTestStatus = ""; hfpTestFile = nil
        let request = UUID(), target = selectedID
        hfpRequest = request
        let begin: (Bool) -> Void = { [weak self] allowed in
            guard let self, self.hfpPreparing, self.hfpRequest == request, self.selectedID == target else { return }
            self.hfpPreparing = false
            guard allowed else { self.hfpTestStatus = "麦克风权限未允许，请在系统隐私设置中允许 MicBridge。"; return }
            self.observeSystemAudio()
            guard self.canTestHFP else { self.hfpTestStatus = "当前输入或连接状态已变化，请恢复连接后重新测试。"; return }
            do {
                let url = try self.newRecording().deletingLastPathComponent().appendingPathComponent("HFP-Test-\(UUID().uuidString).wav")
                let test = try HFPTestRecorder(target: target, url: url)
                self.hfpTest = test; self.hfpRecording = true; self.recording = true
                self.lastHFPTestAudio = nil; self.seconds = 0
                self.signalView.begin(sampleRate: test.sampleRate)
                test.samples = { [weak self, weak test] samples, seconds in
                    guard let self, let test, self.hfpTest === test else { return }
                    self.seconds = seconds; self.lastHFPTestAudio = self.uptime
                    self.signalView.append(samples)
                }
                test.failed = { [weak self] message in self?.stopHFPTest(reason: message) }
                test.limitReached = { [weak self] in self?.stopHFPTest() }
                try test.start()
                self.status = "正在测试当前发射器的 HFP 输入；未打开 SPP。"
                self.updateConnectionState()
            } catch { self.stopHFPTest(reason: error.localizedDescription) }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { begin(allowed) } }
        default: begin(false)
        }
    }
    private func stopHFPTest(reason: String? = nil) {
        hfpRequest = UUID(); hfpPreparing = false
        let test = hfpTest; hfpTest = nil
        var message = reason
        if let test {
            do {
                let duration = try test.stop()
                if duration > 0 { hfpTestFile = test.url }
                if message == nil { message = duration > 0 ? String(format: "已保存 %.1f 秒测试录音 · %.0f kHz · 单声道", duration, test.sampleRate / 1000) : "未收到音频，请恢复连接后重新测试。" }
            } catch { message = error.localizedDescription; hfpTestFile = nil }
            signalView.end()
        }
        hfpRecording = false; recording = session?.isRecording == true
        lastHFPTestAudio = nil; hfpTestStatus = message ?? "已取消 HFP 测试。"
        reloadFiles(); observeSystemAudio(); updateConnectionState()
    }
    func playHFPTest() {
        guard !hfpBusy, !active, !closing, let url = hfpTestFile else { return }
        if playing == url { stopPlayback(); return }
        do {
            let output = try prepareHFPTestPlaybackOutput()
            play(url)
            hfpTestStatus = playing == url ? "正在试听 · 输出：\(output)" : status
        } catch { hfpTestStatus = error.localizedDescription }
    }
    func reloadFiles() {
        guard !preview else { files = []; return }
        files = ((try? FileManager.default.contentsOfDirectory(at: recordingFolder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    func chooseFolder() {
        guard !recording, !hfpBusy, !importing else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "选择录音文件夹"; panel.directoryURL = recordingFolder
        if panel.runModal() == .OK, let url = panel.url { recordingFolder = url; defaults.set(url, forKey: "recordingFolder"); reloadFiles() }
    }
    func revealFolder() {
        do { try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(recordingFolder) }
        catch { status = error.localizedDescription }
    }
    func importCapture() {
        guard !active, !hfpBusy, !importing else { return }
        let panel = NSOpenPanel(); panel.message = "导入 Mic 2 SPP 原始数据；离线解码，不连接设备。"
        guard panel.runModal() == .OK, let input = panel.url else { return }
        do {
            let output = try newRecording(); importing = true; stopPlayback(); status = "正在离线解码…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try decodeCapture(input: input, output: output) }
                DispatchQueue.main.async {
                    guard let self else { return }; self.importing = false
                    switch result { case .success(let summary): self.status = "已导入 \(summary.seconds) 秒录音"; self.reloadFiles()
                    case .failure(let error): self.status = error.localizedDescription }
                    self.finishTermination()
                }
            }
        } catch { status = error.localizedDescription }
    }
    func play(_ url: URL) {
        guard !recording, !hfpBusy, !closing else { return }
        if playing == url { stopPlayback(); return }
        stopPlayback()
        do {
            try AudioRoutes.checkPlaybackOutput()
            let p = try AVAudioPlayer(contentsOf: url); p.delegate = self
            guard p.play() else { throw StreamError.invalid("无法播放录音") }
            player = p; playing = url
        } catch { status = error.localizedDescription }
    }
    func stopPlayback() { player?.stop(); player = nil; playing = nil }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stopPlayback() }
    func updateLaunchStatus() {
        guard !preview else { launchStatus = "界面预览：未注册登录项"; return }
        let state = SMAppService.mainApp.status
        launchEnabled = state == .enabled || state == .requiresApproval
        launchNeedsApproval = state == .requiresApproval
        switch state {
        case .enabled: launchStatus = "已启用 · 登录后在菜单栏运行"
        case .requiresApproval: launchStatus = "等待 macOS 在“登录项”中批准"
        case .notRegistered: launchStatus = "未启用"
        case .notFound: launchStatus = "系统未找到此 App；请将 App 放在固定位置后重试"
        @unknown default: launchStatus = "系统状态未知"
        }
    }
    func setLaunch(_ enabled: Bool) {
        guard !preview else { return }
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; updateLaunchStatus() }
        catch { updateLaunchStatus(); launchStatus = "设置失败：\(error.localizedDescription)" }
    }
    func requestTermination(restoreHFP: Bool) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        if readingMini2Firmware { mini2FirmwareReader.cancel() }
        // An explicit restore already in progress still requires its ACK.
        terminationRestoresHFP = restoreHFP || exitPending || exitPolicy.closeAuthorized
        stopSystemMicrophone()
        resumePolicy.cancel()
        if hfpBusy { stopHFPTest() }
        stopPlayback()
        if session != nil {
            if terminationRestoresHFP && closing && !exitPolicy.closeAuthorized {
                exitStatus = "SPP 已在关闭，无法补发 12/65；请等待关闭结果，必要时重启发射器。"
                showWindowAction?(); return .terminateCancel
            }
            terminating = true
            if !exitPending && !closing {
                if terminationRestoresHFP { beginAcknowledgedExit() }
                else {
                    // Release local resources without deleting the TX reconnect state.
                    // Defer completion until AppKit has received terminateLater.
                    prepareButtonExit(); localClosePending = true
                    DispatchQueue.main.async { [weak self] in self?.driveControlActions() }
                }
            }
            return .terminateLater
        }
        if importing { terminating = true; return .terminateLater }
        return .terminateNow
    }
    private func finishTermination() {
        guard terminating, session == nil, !importing else { return }
        terminating = false; finishedTermination?(!captureBlocked)
        if captureBlocked { showWindowAction?() }
    }
}
