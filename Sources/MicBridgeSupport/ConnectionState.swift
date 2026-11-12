import Foundation

/// Evidence, not a claim about the transmitter's undocumented internal mode.
public struct ConnectionEvidence {
    public var selected = false
    public var supported = true
    public var bluetooth = false
    public var session = false
    public var sppReady = false
    public var hfpCapture = false
    public var hfpRecentAudio = false
    public var hfpIdentified = false
    public var hfpVoiceConnected = false
    public var closing = false
    public var receivedAudio = false
    public var recentAudio = false
    public var closeUnresolved = false
    public var audioReadable = true
    public var inputAvailable = false
    public var systemAudioActive = false
    public init() {}
}

public struct RecoveryObservation: Equatable {
    public private(set) var started: TimeInterval?
    public private(set) var disconnects = 0
    /// Later edges are observations, not evidence of failed recovery in the initial window.
    public private(set) var laterDisconnects = 0
    public private(set) var inputObserved = false
    private var lastConnected = false
    public init() {}
    public mutating func begin(now: TimeInterval, connected: Bool) {
        guard started == nil else { return }
        started = now; lastConnected = connected
    }
    public mutating func observe(connected: Bool, inputAvailable: Bool = false, now: TimeInterval) {
        guard started != nil else { return }
        if connected && inputAvailable { inputObserved = true }
        if lastConnected && !connected {
            if expired(at: now) { laterDisconnects += 1 }
            else { disconnects += 1 }
        }
        lastConnected = connected
    }
    public func elapsed(at now: TimeInterval) -> TimeInterval { started.map { max(0, now - $0) } ?? 0 }
    // A UX observation deadline, not a firmware recovery guarantee.
    public func expired(at now: TimeInterval) -> Bool { started != nil && elapsed(at: now) >= 180 }
}

public enum ConnectionPhase: String, CaseIterable {
    case noDevice, unsupported, disconnected, connecting, streaming, stalled, closing
    case recovering, closeUnconfirmed, recoveryTimedOut, repeatedDisconnects
    case bluetoothOnly, hfpAvailable, systemAudioActive, observationUnavailable
    case sppConnected, hfpReady, hfpVoiceActive, hfpTesting, hfpRecording
    public var title: String {
        switch self {
        case .noDevice: return "等待选择设备"
        case .unsupported: return "暂不支持此型号"
        case .disconnected: return "蓝牙未连接"
        case .connecting: return "SPP 连接中"
        case .streaming: return "SPP 收音中"
        case .stalled: return "SPP 音频中断"
        case .closing: return "正在退出 SPP"
        case .recovering: return "等待蓝牙恢复"
        case .closeUnconfirmed: return "退出状态待确认"
        case .recoveryTimedOut: return "恢复等待超时"
        case .repeatedDisconnects: return "蓝牙反复断连"
        case .bluetoothOnly: return "蓝牙已连接"
        case .hfpAvailable, .hfpReady: return "蓝牙已连接"
        case .hfpVoiceActive: return "HFP 语音链路已建立"
        case .sppConnected: return "SPP 已连接"
        case .hfpTesting: return "HFP 测试中"
        case .hfpRecording: return "HFP 收音中"
        case .systemAudioActive: return "DJI 系统音频使用中"
        case .observationUnavailable: return "音频状态暂不可读"
        }
    }
    public var warning: Bool {
        [.stalled, .closeUnconfirmed, .recoveryTimedOut, .repeatedDisconnects, .observationUnavailable].contains(self)
    }
    public var symbol: String {
        if warning { return "exclamationmark.triangle" }
        switch self {
        case .streaming, .hfpRecording: return "waveform"
        case .closing, .recovering, .connecting: return "arrow.triangle.2.circlepath"
        case .hfpAvailable, .hfpReady, .hfpVoiceActive, .systemAudioActive: return "mic"
        default: return "antenna.radiowaves.left.and.right"
        }
    }
    public var detail: String {
        switch self {
        case .noDevice: return "选择已配对的发射器，查看连接与收音状态。"
        case .unsupported: return "此型号暂不支持连接或发送指令。"
        case .disconnected: return "等待发射器连接到 Mac。"
        case .connecting: return "正在建立 SPP 会话，等待有效音频。"
        case .streaming: return "持续收到并解码音频；停止保存录音不会关闭连接。"
        case .stalled: return "超过 3 秒未收到音频。"
        case .closing: return "已请求关闭通道；自动进入 SPP 已暂停。"
        case .recovering: return "退出后允许一次短暂断连；等待发射器重新连接，不主动重开 SPP。"
        case .closeUnconfirmed: return "退出尚未完成，请查看诊断记录。"
        case .recoveryTimedOut: return "等待已超过 3 分钟，尚未观察到可用的普通蓝牙输入。"
        case .repeatedDisconnects: return "本轮退出观察到多次断连，超出允许一次闪断的预期。"
        case .bluetoothOnly: return "蓝牙已连接，系统尚未提供此发射器的音频输入。"
        case .hfpAvailable: return "系统已枚举到此发射器的输入端点；可连接 SPP 开始收音。"
        case .hfpReady: return "系统已识别此发射器的 HFP 输入端点；发射器的普通录音状态需结合退出 SPP 流程判断。"
        case .hfpVoiceActive: return "HFP 语音链路已建立，系统音频正在使用。"
        case .sppConnected: return "SPP 通道已就绪，等待可解码音频。"
        case .hfpTesting: return "已开始测试普通蓝牙输入，等待音频；不会自动进入 SPP。"
        case .hfpRecording: return "正在从所选发射器的普通蓝牙输入接收并保存音频，可停止后试听。"
        case .systemAudioActive: return "DJI 的系统音频输入或输出正在使用。"
        case .observationUnavailable: return "读取系统音频属性失败，暂不推断普通蓝牙收音状态。"
        }
    }
    public static func resolve(_ e: ConnectionEvidence, recovery: RecoveryObservation, now: TimeInterval) -> Self {
        guard e.selected else { return .noDevice }
        guard e.supported else { return .unsupported }
        if e.closing { return .closing }
        if e.session && e.bluetooth {
            if e.receivedAudio { return e.recentAudio ? .streaming : .stalled }
            return e.sppReady ? .sppConnected : .connecting
        }
        if recovery.disconnects > 1 { return .repeatedDisconnects }
        if e.closeUnresolved { return .closeUnconfirmed }
        if !e.bluetooth {
            if recovery.started == nil || (recovery.expired(at: now) && recovery.inputObserved) { return .disconnected }
            return recovery.expired(at: now) ? .recoveryTimedOut : .recovering
        }
        if e.hfpCapture { return e.hfpRecentAudio ? .hfpRecording : .hfpTesting }
        guard e.audioReadable else { return .observationUnavailable }
        if e.inputAvailable {
            if e.hfpVoiceConnected && e.systemAudioActive { return .hfpVoiceActive }
            if e.systemAudioActive { return .systemAudioActive }
            return e.hfpIdentified ? .hfpReady : .hfpAvailable
        }
        if recovery.started != nil && !(recovery.expired(at: now) && recovery.inputObserved) {
            return recovery.expired(at: now) ? .recoveryTimedOut : .recovering
        }
        return .bluetoothOnly
    }
}
