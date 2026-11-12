/// In-memory intent for an already working SPP session. Does not change the
/// launch-time auto-connect preference, save recordings, or reconnect Bluetooth.
public struct SPPResumePolicy {
    private var target: String?
    private var receivedAudio = false
    private var pending = false
    public init() {}
    public mutating func begin(target: String) {
        self.target = target; receivedAudio = false; pending = false
    }
    public mutating func audioReceived(target: String) {
        guard self.target == target, !pending else { return }
        receivedAudio = true
    }
    public mutating func linkLost(target: String) {
        guard self.target == target, receivedAudio else { return }
        pending = true
    }
    public func shouldResume(target: String) -> Bool { self.target == target && pending }
    /// Explicit exit, 12/65 (before sending), HFP test, errors and device changes.
    /// Late PCM and disconnect callbacks cannot revive a cancelled intent.
    public mutating func cancel() { target = nil; receivedAudio = false; pending = false }
}
