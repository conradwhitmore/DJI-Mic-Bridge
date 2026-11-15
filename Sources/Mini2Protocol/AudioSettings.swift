import Foundation

public enum MiniNoiseMode: String, CaseIterable {
    case off, weak, strong
    public var title: String {
        switch self { case .off: return "关闭"; case .weak: return "弱降噪"; case .strong: return "强降噪" }
    }
}
public enum MiniVoiceTone: UInt8, CaseIterable {
    case standard = 1, rich = 2, bright = 3
    public var title: String {
        switch self { case .standard: return "常规"; case .rich: return "饱满"; case .bright: return "明亮" }
    }
}

/// Wireless commands, not DUML; values are restricted to firmware-supported choices.
public enum MiniAudioCommand: Equatable {
    case denoise(Bool), level(MiniNoiseMode), tone(MiniVoiceTone)
    public var packet: [UInt8] {
        let command: UInt8, value: UInt8
        switch self {
        case .denoise(let enabled): command = 0x11; value = enabled ? 1 : 0
        case .level(let mode): command = 0x14; value = mode == .strong ? 1 : 0
        case .tone(let tone): command = 0x19; value = tone.rawValue
        }
        var frame: [UInt8] = [0x55, 9, 0x58, 0, 0x19, 0, 0, command, value]
        frame[3] = UInt8(frame[4...].reduce(0) { $0 + Int($1) } & 63)
        var result: [UInt8] = [0xaa, 4, 0]
        result += frame; result += [UInt8](repeating: 0, count: 116); result.append(0xa5)
        return result
    }
    fileprivate func matches(_ status: Mini2SPPStatus) -> Bool {
        switch self {
        case .denoise(let value): return status.denoise == value
        case .level(let mode): return status.denoiseLevel == (mode == .strong ? 1 : 0)
        case .tone(let tone): return status.voiceTone == tone
        }
    }
}

public extension Mini2SPPStatus {
    var voiceTone: MiniVoiceTone? { MiniVoiceTone(rawValue: bytes[15] & 3) }
    var noiseMode: MiniNoiseMode? {
        if !denoise { return .off }
        switch denoiseLevel { case 0: return .weak; case 1: return .strong; default: return nil }
    }
}

/// Serial writes, followed by fresh status confirmation; never treats write completion as an ACK.
public struct MiniAudioSettings {
    public struct ViewState: Equatable {
        public var noiseMode: MiniNoiseMode?
        public var tone: MiniVoiceTone?
        public var ready = false
        public var busy = false
        public var error: String?
        public init() {}
    }
    private let model: MiniTransmitterModel
    private var latest: Mini2SPPStatus?
    private var latestAt: TimeInterval = -.infinity
    private var queue: [MiniAudioCommand] = []
    private var pending: MiniAudioCommand?
    private var sentAt: TimeInterval = 0
    private var writeFinished = false
    private var matches = 0
    private var lastMatch: TimeInterval = -.infinity
    public private(set) var error: String?
    public var busy: Bool { pending != nil || !queue.isEmpty }
    public init(model: MiniTransmitterModel) { self.model = model }
    public func view(at time: TimeInterval) -> ViewState {
        var state = ViewState()
        state.ready = latest != nil && time >= latestAt && time - latestAt < 2
        state.noiseMode = state.ready ? latest?.noiseMode : nil
        state.tone = state.ready && model == .mini2 ? latest?.voiceTone : nil
        state.busy = busy; state.error = error
        return state
    }
    @discardableResult public mutating func requestNoise(_ mode: MiniNoiseMode, at time: TimeInterval) -> Bool {
        guard !busy, view(at: time).ready, let latest else { return false }
        error = nil
        if mode == .off {
            if latest.denoise { queue = [.denoise(false)] }
        } else {
            let level: UInt8 = mode == .strong ? 1 : 0
            if latest.denoiseLevel != level { queue.append(.level(mode)) }
            if !latest.denoise { queue.append(.denoise(true)) }
        }
        return true
    }
    @discardableResult public mutating func requestTone(_ tone: MiniVoiceTone, at time: TimeInterval) -> Bool {
        guard model == .mini2, !busy, view(at: time).ready, let latest else { return false }
        error = nil
        if latest.voiceTone != tone { queue = [.tone(tone)] }
        return true
    }
    public mutating func nextCommand(at time: TimeInterval) -> MiniAudioCommand? {
        guard pending == nil, !queue.isEmpty else { return nil }
        guard view(at: time).ready else { fail("设备状态已中断，请连接后重试"); return nil }
        let command = queue.removeFirst()
        pending = command; sentAt = time; matches = 0; lastMatch = -.infinity; writeFinished = false
        return command
    }
    public mutating func writeCompleted(success: Bool) {
        guard pending != nil else { return }
        if success { writeFinished = true } else { fail("设置发送失败，请重试") }
    }
    public mutating func observe(_ status: Mini2SPPStatus, at time: TimeInterval) {
        guard time.isFinite, time >= latestAt else { return }
        latest = status; latestAt = time
        expire(at: time)
        guard let pending, writeFinished, time >= sentAt + 0.3 else { return }
        guard pending.matches(status) else { matches = 0; lastMatch = -.infinity; return }
        guard time - lastMatch >= 0.05 else { return }
        matches += 1; lastMatch = time
        if matches >= 3 { self.pending = nil }
    }
    public mutating func expire(at time: TimeInterval) {
        if pending != nil && time >= sentAt + 6 { fail("设备未确认设置，请重试") }
    }
    public mutating func fail(_ message: String) { cancel(); error = message }
    public mutating func cancel() { queue.removeAll(); pending = nil; writeFinished = false; error = nil }
}
