/// Output candidates are alive, have output streams and are not DJI endpoints.
/// Unlike input protection, a user's valid selection always wins.
public enum SPPOutputSelection {
    public struct Candidate {
        public let id: UInt32
        public let uid: String
        public let builtIn: Bool
        public let fallback: Bool
        public init(id: UInt32, uid: String, builtIn: Bool = false, fallback: Bool = true) {
            self.id = id; self.uid = uid; self.builtIn = builtIn; self.fallback = fallback
        }
    }
    public static func choose(_ candidates: [Candidate], current: UInt32?, previousUID: String?) -> UInt32? {
        if let current, candidates.contains(where: { $0.id == current }) { return current }
        if let previousUID, let previous = candidates.first(where: { $0.uid == previousUID }) { return previous.id }
        return candidates.first(where: { $0.builtIn && $0.fallback })?.id
            ?? candidates.first(where: { $0.fallback })?.id
    }
}
