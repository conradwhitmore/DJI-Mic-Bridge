import Foundation

/// Candidates have already passed alive, input-stream and identity checks.
/// Loopbacks always outrank physical inputs; outputs never use this policy.
public enum SPPInputSelection {
    public struct Candidate {
        public let id: UInt32
        public let bridge: VirtualInputIdentity.Profile?
        public let builtIn: Bool
        public init(id: UInt32, bridge: VirtualInputIdentity.Profile? = nil, builtIn: Bool = false) {
            self.id = id; self.bridge = bridge; self.builtIn = builtIn
        }
    }
    public static func choose(_ candidates: [Candidate], current: UInt32?, locked: UInt32? = nil) -> UInt32? {
        for profile in VirtualInputIdentity.Profile.allCases {
            if let bridge = candidates.first(where: { $0.bridge == profile }) { return bridge.id }
        }
        if let locked, candidates.contains(where: { $0.id == locked }) { return locked }
        if let current, candidates.contains(where: { $0.id == current }) { return current }
        return candidates.first(where: { $0.builtIn })?.id ?? candidates.first?.id
    }
}
