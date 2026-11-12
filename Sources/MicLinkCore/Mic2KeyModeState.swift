import Foundation

/// Per-connection mode transaction. Preferences belong to the caller, not the TX.
/// Entry reads fresh configuration to avoid interrupting transmitter recording.
/// Exit never requires a settings read, so it remains usable for recovery.
public struct Mic2KeyModeState {
    private var desired = false
    private var reading = false
    private var awaiting = false
    private var deadline: TimeInterval = 0
    public private(set) var enabled: Bool?
    public private(set) var busy = false
    public private(set) var error: String?
    public init() {}
    public mutating func setEnabled(_ value: Bool, now: TimeInterval) {
        guard !busy else { return }
        desired = value; reading = value; awaiting = false; busy = true
        error = nil; deadline = now + 25
    }
    public var request: MicControlCommand? {
        guard busy, !awaiting else { return nil }
        return reading ? .audioConfiguration : (desired ? .keyTestOn : .keyTestOff)
    }
    public mutating func sent() { awaiting = true }
    public mutating func expire(now: TimeInterval) {
        if busy && now >= deadline { fail("热键模式切换超时") }
    }
    public mutating func fail(_ message: String) {
        busy = false; awaiting = false; enabled = nil; error = message
    }
    public mutating func receive(_ command: MicControlCommand, result: Result<[UInt8], Error>) {
        guard busy, awaiting,
              command == (reading ? .audioConfiguration : (desired ? .keyTestOn : .keyTestOff)) else { return }
        do {
            let payload = try result.get()
            if reading {
                _ = try Mic2AudioConfiguration(reply: payload)
                guard payload[18] & 1 == 0 else { throw StreamError.invalid("请先停止发射器本地录音，再启用热键模式") }
                reading = false; awaiting = false
            } else {
                guard payload == [0, 0x43, 1, desired ? 1 : 0] else { throw StreamError.invalid("热键模式应答不匹配") }
                enabled = desired; busy = false; awaiting = false; error = nil
            }
        } catch { fail(error.localizedDescription) }
    }
}
