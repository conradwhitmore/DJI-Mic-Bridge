import Foundation

public enum Mini2Hotkey: String, CaseIterable {
    case connection, powerDouble
    public var title: String { self == .connection ? "连接键单击" : "电源键双击" }
}

/// Power-double is a noise-cancellation state proxy, never a raw key report.
/// Caller supplies only checksum-validated status frames, once per frame.
public struct Mini2SPPHotkeys {
    private var denoise: Bool?
    private var lastTime: TimeInterval?
    private var suppressUntil: TimeInterval = -.infinity
    public init() {}
    public mutating func resetBaseline() { denoise = nil; lastTime = nil }
    public mutating func softwareDenoiseWrite(at time: TimeInterval) { suppressUntil = time + 6.5 }
    public mutating func observe(_ status: Mini2SPPStatus, at time: TimeInterval) -> [Mini2Hotkey] {
        guard time.isFinite else { return [] }
        var result: [Mini2Hotkey] = []
        if status.capture == 1 { result.append(.connection) }
        if let previous = denoise, let lastTime, time >= lastTime, time - lastTime < 1,
           time > suppressUntil, !status.denoiseButtonDisabled, previous != status.denoise {
            result.append(.powerDouble)
        }
        denoise = status.denoise; lastTime = time
        return result
    }
}
