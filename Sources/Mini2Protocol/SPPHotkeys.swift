import Foundation

/// Both generations share the SPP layout; firmware selects a different power gesture.
public enum MiniTransmitterModel: String, CaseIterable {
    case mini, mini2
    public var powerHotkey: Mini2Hotkey { self == .mini ? .powerSingle : .powerDouble }
    public var advertisedNamePrefix: String { self == .mini ? "DJIMICMINI" : "DJIMICMINI2" }
}

public enum Mini2Hotkey: String, CaseIterable {
    case connection, powerSingle, powerDouble, connectionDouble
    public var title: String {
        switch self {
        case .connection: return "连接键单击"
        case .connectionDouble: return "连接键双击"
        case .powerSingle: return "电源键单击"
        case .powerDouble: return "电源键双击"
        }
    }
}

/// The power gesture is a noise-cancellation state proxy, never a raw key report.
/// Caller supplies only checksum-validated status frames, once per frame.
public struct Mini2SPPHotkeys {
    private var denoise: Bool?
    private var lastTime: TimeInterval?
    private var suppressUntil: TimeInterval = -.infinity
    private let model: MiniTransmitterModel
    public init(model: MiniTransmitterModel = .mini2) { self.model = model }
    public mutating func resetBaseline() { denoise = nil; lastTime = nil }
    public mutating func softwareDenoiseWrite(at time: TimeInterval) { suppressUntil = time + 6.5 }
    public mutating func observe(_ status: Mini2SPPStatus, at time: TimeInterval) -> [Mini2Hotkey] {
        guard time.isFinite else { return [] }
        var result: [Mini2Hotkey] = []
        if status.capture == 1 { result.append(.connection) }
        if let previous = denoise, let lastTime, time >= lastTime, time - lastTime < 1,
           time > suppressUntil, !status.denoiseButtonDisabled, previous != status.denoise {
            result.append(model.powerHotkey)
        }
        denoise = status.denoise; lastTime = time
        return result
    }
}
