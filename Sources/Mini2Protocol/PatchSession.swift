import Foundation

/// Per-SPP-session capability and mode negotiation. Never uses cached firmware identity.
public struct Mini2PatchSession: Equatable {
    public private(set) var identity: Mini2PatchIdentity?
    public private(set) var pending: Mini2SPPCommand?
    public private(set) var error: String?
    public private(set) var mayBeEnabled = false
    private var sequence: UInt16 = 0
    private var deadline: TimeInterval = 0
    private var nextProbe: TimeInterval = 0
    private var probes = 0
    private var attemptedDesired: Bool?
    public init() {}
    public var busy: Bool { pending != nil }
    public var advancedAvailable: Bool { identity?.supportsDoubleClicks == true }
    public var enabled: Bool { identity?.mode == .enabled && !busy && error == nil }
    public var allowsStockEvents: Bool { !mayBeEnabled && !busy && (identity != nil || probes >= 3) }
    public mutating func retry() { error = nil; attemptedDesired = nil; if identity == nil { probes = 0 } }
    public mutating func next(desired: Bool, closing: Bool = false, sequence: UInt16, now: TimeInterval) -> [UInt8]? {
        if pending != nil, now >= deadline {
            let wasProbe = pending == .patchIdentity
            pending = nil; nextProbe = now + 1
            if !wasProbe { error = "按键模式回应超时；状态未确认，请重试或断开连接" }
        }
        guard pending == nil, now >= nextProbe else { return nil }
        let command: Mini2SPPCommand
        if identity == nil {
            // Never need to probe a stock device during teardown.
            guard !closing, probes < 3 else { return nil }
            probes += 1; command = .patchIdentity
        } else if closing {
            guard mayBeEnabled else { return nil }
            guard attemptedDesired != false || error == nil else { return nil }
            command = .patchDisable; attemptedDesired = false
        } else {
            guard advancedAvailable, identity?.mode != .factoryBusy,
                  (identity?.mode == .enabled) != desired || mayBeEnabled != desired,
                  attemptedDesired != desired else { return nil }
            command = desired ? .patchEnable : .patchDisable; attemptedDesired = desired
        }
        if command == .patchEnable { mayBeEnabled = true }
        pending = command; self.sequence = sequence; deadline = now + 4
        return command.packet(sequence: sequence)
    }
    @discardableResult public mutating func receive(_ frame: Mini2Frame) -> Bool {
        guard let pending, pending.matches(frame, sequence: sequence), let value = Mini2PatchIdentity(frame) else { return false }
        self.pending = nil; identity = value; error = nil
        mayBeEnabled = value.mode != .disabled
        if pending != .patchIdentity && value.mode != (pending == .patchEnable ? .enabled : .disabled) {
            error = "设备未切换至请求的按键模式"
        }
        return true
    }
    public func accepts(_ event: Mini2Hotkey) -> Bool { enabled && identity?.accepts(event) == true }
}
