import Foundation

/// Restores only the supplied, locked defaults through injected operations.
/// There are no platform or audio APIs here. A failure on one selector never skips
/// the remaining selectors, and a successful write is always followed by a read.
public enum LockedRouteRestorer {
    public enum Stage: String, Equatable {
        case availability, read, write, verification
    }

    public struct Failure: Equatable {
        public let selector: UInt32
        public let expectedDevice: UInt32
        public let stage: Stage
        public let message: String
    }

    /// Operations run synchronously in selector order. No retry or alternate
    /// device is selected. A matching default is checked for availability but
    /// never rewritten. Returned failures preserve the selector order.
    public static func restore(
        selectors: [UInt32],
        locked: [UInt32: UInt32],
        isAlive: (UInt32) throws -> Bool,
        readDefault: (UInt32) throws -> UInt32,
        writeDefault: (UInt32, UInt32) throws -> Void
    ) -> [Failure] {
        var failures: [Failure] = []
        for selector in selectors {
            guard let expected = locked[selector] else { continue }
            var stage = Stage.availability
            do {
                guard try isAlive(expected) else {
                    failures.append(Failure(selector: selector, expectedDevice: expected,
                                            stage: stage, message: "锁定的音频设备不可用"))
                    continue
                }
                stage = .read
                guard try readDefault(selector) != expected else { continue }
                stage = .write
                try writeDefault(selector, expected)
                stage = .verification
                let actual = try readDefault(selector)
                if actual != expected {
                    failures.append(Failure(selector: selector, expectedDevice: expected,
                                            stage: stage,
                                            message: "音频路由恢复后验证失败：期望设备 \(expected)，实际设备 \(actual)"))
                }
            } catch {
                failures.append(Failure(selector: selector, expectedDevice: expected,
                                        stage: stage, message: error.localizedDescription))
            }
        }
        return failures
    }
}
