import Foundation

/// Experimental dm202b SPP extension. Presence is established afresh on each connection.
/// No inference from the official firmware version or a previous connection's cache.
public struct Mini2PatchIdentity: Equatable {
    public enum Mode: UInt8 { case disabled = 0, enabled = 1, factoryBusy = 2 }
    public let revision: UInt16
    public let capabilities: UInt16
    public let mode: Mode
    public let result: UInt8
    public var supportsKeyMode: Bool { capabilities & 0x000f == 0x000f }
    public var supportsDoubleClicks: Bool { supportsKeyMode && capabilities & 0x0010 != 0 }
    public func accepts(_ key: Mini2Hotkey) -> Bool {
        guard mode == .enabled, supportsKeyMode else { return false }
        return (key == .connection || key == .powerSingle) || supportsDoubleClicks
    }
    public init?(_ frame: Mini2Frame) {
        let p = frame.payload
        guard frame.source == 0x3a, frame.destination == 2, frame.flags == 0x80,
              frame.commandSet == 0x3f, frame.commandID == 0xf0,
              p.count == 11, Array(p.prefix(5)) == [0x4d, 0x42, 0x52, 0x47, 1],
              let mode = Mode(rawValue: p[9]), p[10] == (mode == .factoryBusy ? 2 : 0) else { return nil }
        revision = UInt16(p[5]) | UInt16(p[6]) << 8
        capabilities = UInt16(p[7]) | UInt16(p[8]) << 8
        self.mode = mode; result = p[10]
    }
}

public extension Mini2Frame {
    /// Distinct from stock capture/denoise proxies and original factory 04/68 events.
    var patchKey: Mini2Hotkey? {
        let p = payload
        guard source == 0x3a, destination == 2, flags == 0x80,
              commandSet == 0x3f, commandID == 0xf1,
              p.count == 6, Array(p.prefix(5)) == [0x4d, 0x42, 0x52, 0x47, 1] else { return nil }
        switch p[5] {
        case 6: return .connection
        case 7: return .powerSingle
        case 8: return .connectionDouble
        case 9: return .powerDouble
        default: return nil
        }
    }
}
