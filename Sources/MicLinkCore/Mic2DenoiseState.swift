import Foundation

/// Serialized read / modify / verify transaction. The caller owns transport and
/// cancels this state when its SPP session ends. No automatic write retries.
public struct Mic2DenoiseState {
    public struct Request {
        public let command: MicControlCommand
        public let configuration: Mic2AudioConfiguration?
    }
    private enum Step { case read, write, verify }
    private var step: Step?
    private var desired: Bool?
    private var original: Mic2AudioConfiguration?
    private var awaiting = false
    private var deadline: TimeInterval = 0
    public private(set) var enabled: Bool?
    public private(set) var error: String?
    public var busy: Bool { step != nil }
    public init() {}

    public mutating func read(now: TimeInterval) {
        guard !busy else { return }
        desired = nil; begin(now: now)
    }
    public mutating func setEnabled(_ enabled: Bool, now: TimeInterval) {
        guard !busy else { return }
        desired = enabled; begin(now: now)
    }
    private mutating func begin(now: TimeInterval) {
        step = .read; awaiting = false; original = nil; error = nil; deadline = now + 30
    }
    public mutating func expire(now: TimeInterval) {
        if busy && now >= deadline { fail("操作超时，请重试") }
    }
    public var request: Request? {
        guard !awaiting, let step else { return nil }
        switch step {
        case .read, .verify: return Request(command: .audioConfiguration, configuration: nil)
        case .write: return Request(command: desired == true ? .denoiseOn : .denoiseOff, configuration: original)
        }
    }
    public mutating func sent() { awaiting = true }
    public mutating func fail(_ message: String) {
        step = nil; awaiting = false; enabled = nil; original = nil; desired = nil; error = message
    }
    public mutating func receive(_ command: MicControlCommand, result: Result<[UInt8], Error>) {
        guard awaiting, let step else { return }
        let expected: MicControlCommand = step == .write ? (desired == true ? .denoiseOn : .denoiseOff) : .audioConfiguration
        guard command == expected else { return }
        awaiting = false
        do {
            let payload = try result.get()
            switch step {
            case .read:
                let config = try Mic2AudioConfiguration(reply: payload)
                enabled = config.denoiseEnabled
                if let desired, desired != config.denoiseEnabled {
                    _ = try config.denoiseWritePayload(enabled: desired)
                    original = config; self.step = .write
                } else { finish() }
            case .write:
                guard payload == [0] else { throw StreamError.invalid("设置未成功，请重试") }
                self.step = .verify
            case .verify:
                let config = try Mic2AudioConfiguration(reply: payload)
                guard let original, let desired, config.matches(original, denoiseEnabled: desired) else {
                    throw StreamError.invalid("设置回读不一致，请重新读取")
                }
                enabled = config.denoiseEnabled; finish()
            }
        } catch { fail(error.localizedDescription) }
    }
    private mutating func finish() { step = nil; awaiting = false; original = nil; desired = nil; error = nil }
}
