/// One automatic attempt per observed Bluetooth connection, after readiness settles.
/// This policy never initiates a Bluetooth connection or retries a failed SPP open.
public final class AutoSPPPolicy {
    private var readySince: Double?
    private var attempted = false
    public init() {}
    public func linkDisconnected() { readySince = nil; attempted = false }
    public func markAttempted() { readySince = nil; attempted = true }
    public func shouldConnect(enabled: Bool, connected: Bool, ready: Bool,
                              busy: Bool, now: Double) -> Bool {
        guard enabled, connected else { linkDisconnected(); return false }
        guard !attempted, !busy else { return false }
        guard ready else { readySince = nil; return false }
        guard let since = readySince else { readySince = now; return false }
        guard now - since >= 1 else { return false }
        markAttempted()
        return true
    }
}
