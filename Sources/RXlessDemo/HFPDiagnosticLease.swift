#if HFP_DIAGNOSTIC
/// One explicitly armed 30-second exception; never persisted or renewed.
struct HFPDiagnosticLease {
    private(set) var used = false
    private(set) var deadline: Double?
    mutating func begin(now: Double) -> Bool {
        guard !used, now.isFinite else { return false }
        used = true; deadline = now + 30
        return true
    }
    func allowsInput(now: Double) -> Bool {
        guard let deadline, now.isFinite else { return false }
        return now < deadline
    }
    mutating func end() { deadline = nil }
}
#endif
