/// Serializes explicit exit behind a validated 12/65 ACK. It never retries a
/// command whose write may already have reached the transmitter.
public struct SPPExitPolicy {
    public enum Action: Equatable { case none, sendCommand, closeChannel, fail }
    private enum State { case idle, waiting, closing, failed }
    private var state = State.idle
    private var accepted: Bool?
    private var deadline: Double = 0
    public init() {}
    public var failed: Bool { state == .failed }
    public var closeAuthorized: Bool { state == .closing }
    public var pending: Bool { state == .waiting || state == .closing }
    public mutating func request(now: Double) {
        guard !pending else { return }
        state = .waiting; deadline = now + 12
    }
    public mutating func advance(canQuery: Bool, alreadySent: Bool, now: Double) -> Action {
        guard state == .waiting else { return .none }
        if let accepted {
            state = accepted ? .closing : .failed
            return accepted ? .closeChannel : .fail
        }
        guard now < deadline else { state = .failed; return .fail }
        guard canQuery, !alreadySent else { return .none }
        // The transport sets alreadySent before writing. Keep one bounded reply wait.
        deadline = now + 10
        return .sendCommand
    }
    public mutating func reply(success: Bool) { accepted = success }
    public mutating func fail() { state = .failed }
}
