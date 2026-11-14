import Foundation
import MicLinkCore

/// Mini 2 02.03.17.00 candidates. These are raw DUML for BLE, NOT Mic 2 SPP packets.
public enum Mini2Command: String {
    case version, battery, keyEnter, keyExit
    public var code: (UInt8, UInt8) {
        switch self {
        case .version: return (0, 1)
        case .battery: return (5, 6)
        case .keyEnter, .keyExit: return (4, 0x68)
        }
    }
    public var payload: [UInt8] {
        switch self {
        case .version, .battery: return []
        case .keyEnter: return [0x43, 1, 0]
        case .keyExit: return [0x43, 1, 8]
        }
    }
}

public struct Mini2Frame {
    public let bytes: [UInt8]
    public var source: UInt8 { bytes[4] }
    public var destination: UInt8 { bytes[5] }
    public var sequence: UInt16 { UInt16(bytes[6]) | UInt16(bytes[7]) << 8 }
    public var flags: UInt8 { bytes[8] }
    public var commandSet: UInt8 { bytes[9] }
    public var commandID: UInt8 { bytes[10] }
    public var payload: [UInt8] { Array(bytes[11..<bytes.count - 2]) }
    public init?(_ b: [UInt8]) {
        guard b.count >= 13, b.count <= 1023, b[0] == 0x55, b[2] >> 2 == 1,
              Int(b[1]) | Int(b[2] & 3) << 8 == b.count,
              crc8(Array(b.prefix(3))) == b[3],
              crc16(Array(b.dropLast(2))) == UInt16(b[b.count - 2]) | UInt16(b[b.count - 1]) << 8 else { return nil }
        bytes = b
    }
    /// No sequence deduplication: TX reports may repeatedly use sequence zero.
    /// Mode ACKs echo 00/08, and therefore cannot be mistaken for key 06/07.
    public var independentKey: UInt8? {
        let p = payload
        guard source == 0x3a, [UInt8(2), 0x0a].contains(destination), flags == 0x80,
              commandSet == 4, commandID == 0x68, p.count == 4,
              Array(p.prefix(3)) == [0, 0x43, 1], [UInt8(6), 7].contains(p[3]) else { return nil }
        return p[3]
    }
}

public struct Mini2Request {
    public let command: Mini2Command
    public let sequence: UInt16
    public init(_ command: Mini2Command, sequence: UInt16) { self.command = command; self.sequence = sequence }
    public var packet: [UInt8] {
        let (set, id) = command.code
        var b: [UInt8] = [0x55, UInt8(13 + command.payload.count), 4, 0, 2, 0x3a,
                          UInt8(sequence & 255), UInt8(sequence >> 8), 0x40, set, id]
        b[3] = crc8(Array(b.prefix(3))); b += command.payload
        let c = crc16(b); b += [UInt8(c & 255), UInt8(c >> 8)]
        return b
    }
    public func matches(_ frame: Mini2Frame) -> Bool {
        let (set, id) = command.code
        return frame.source == 0x3a && frame.destination == 2 && frame.flags == 0x80 &&
            frame.sequence == sequence && frame.commandSet == set && frame.commandID == id && frame.independentKey == nil
    }
    public func validate(_ frame: Mini2Frame) throws -> [UInt8] {
        guard matches(frame) else { throw StreamError.invalid("不是当前查询的回应") }
        let p = frame.payload
        switch command {
        case .version:
            guard p.count == 30, p[0] == 0 else { throw StreamError.invalid("版本回应格式不符：\(p.hex)") }
        case .battery:
            guard p.count == 40, p[0] <= 100 else { throw StreamError.invalid("电量回应格式不符：\(p.hex)") }
        case .keyEnter, .keyExit:
            guard p == [0] + command.payload else { throw StreamError.invalid("按键模式回应未确认：\(p.hex)") }
        }
        return p
    }
    public static func version(_ p: [UInt8]) -> String? {
        guard p.count == 30 else { return nil }
        return p[22..<26].reversed().map { String(format: "%02d", $0) }.joined(separator: ".")
    }
    public static func product(_ p: [UInt8]) -> String {
        guard p.count == 30 else { return "" }
        return String(bytes: p[2..<18].prefix { $0 != 0 }, encoding: .ascii) ?? ""
    }
}

/// Incremental BLE framing, including fragmented/coalesced notifications and resynchronization.
public struct Mini2DUMLParser {
    private var buffer: [UInt8] = []
    public private(set) var discardedBytes = 0
    public init() {}
    public mutating func feed(_ data: Data) -> [Mini2Frame] {
        buffer.append(contentsOf: data)
        if buffer.count > 65536 { discardedBytes += buffer.count; buffer.removeAll(); return [] }
        var result: [Mini2Frame] = []
        while buffer.count >= 4 {
            let n = Int(buffer[1]) | Int(buffer[2] & 3) << 8
            guard buffer[0] == 0x55, buffer[2] >> 2 == 1, n >= 13,
                  crc8(Array(buffer.prefix(3))) == buffer[3] else {
                buffer.removeFirst(); discardedBytes += 1; continue
            }
            guard buffer.count >= n else { break }
            if let frame = Mini2Frame(Array(buffer.prefix(n))) {
                result.append(frame); buffer.removeFirst(n)
            } else { buffer.removeFirst(); discardedBytes += 1 }
        }
        return result
    }
}

public struct Mini2Envelope {
    public let version: UInt8
    /// Unclassified 125-byte wireless blocks: some contain capability/control data, not audio.
    public let blocks: [Data]
    public let control: Mini2Frame?
}

/// Capture inspector only. Never passes Mini 2's 112-byte payload to Mic 2's decoder.
public struct Mini2SPPParser {
    private var buffer: [UInt8] = []
    public private(set) var discardedBytes = 0
    public init() {}
    public mutating func feed(_ data: Data) -> [Mini2Envelope] {
        buffer.append(contentsOf: data)
        if buffer.count > 65536 { discardedBytes += buffer.count; buffer.removeAll(); return [] }
        var result: [Mini2Envelope] = []
        while buffer.count >= 3 {
            guard buffer[0] == 0xaa else { buffer.removeFirst(); discardedBytes += 1; continue }
            let count = Int((buffer[1] >> 2) & 15), length = Int(buffer[1] & 3) << 8 | Int(buffer[2])
            let offset = 3 + count * 125, total = offset + length + 1
            guard buffer.count >= total else { break }
            let control = length == 0 ? nil : Mini2Frame(Array(buffer[offset..<offset + length]))
            guard buffer[total - 1] == 0xa5, length == 0 || control != nil else {
                buffer.removeFirst(); discardedBytes += 1; continue
            }
            let blocks = (0..<count).map { Data(buffer[(3 + $0 * 125)..<(3 + ($0 + 1) * 125)]) }
            result.append(Mini2Envelope(version: buffer[1] >> 6, blocks: blocks, control: control))
            buffer.removeFirst(total)
        }
        return result
    }
}

public extension Collection where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// Restricted SPP probe: transient clock handshake and read-only queries.
/// Firmware's SPP DUML dispatcher explicitly handles 58/65; general queries
/// are included to test reachability, never assumed supported from BLE success.
public enum Mini2SPPCommand: String, CaseIterable {
    case clockStart, clockStop, version, battery
    public var code: (UInt8, UInt8) {
        switch self {
        case .clockStart, .clockStop: return (0x12, 0x58)
        case .version: return (0, 1)
        case .battery: return (5, 6)
        }
    }
    public func packet(sequence: UInt16) -> [UInt8] {
        let payload: [UInt8] = self == .clockStart ? [1] : self == .clockStop ? [2] : []
        let (set, id) = code
        var b: [UInt8] = [0x55, UInt8(13 + payload.count), 4, 0, 2, 0x3a,
                         UInt8(sequence & 255), UInt8(sequence >> 8), 0x40, set, id]
        b[3] = crc8(Array(b.prefix(3))); b += payload
        let crc = crc16(b); b += [UInt8(crc & 255), UInt8(crc >> 8)]
        return [0xaa, 0, UInt8(b.count)] + b + [0xa5]
    }
    public func matches(_ frame: Mini2Frame, sequence: UInt16) -> Bool {
        let (set, id) = code
        return frame.source == 0x3a && frame.destination == 2 && frame.flags == 0x80 &&
            frame.sequence == sequence && frame.commandSet == set && frame.commandID == id
    }
}

/// Live sample evidence: 112 bytes are transported, with a zero trailer after
/// 111 encoded bytes. Reject other layouts instead of silently truncating them.
public func mini2AudioPayload(_ block: Data) -> Data? {
    let b = [UInt8](block)
    guard b.count == 125, Array(b[6..<9]) == [0x55, 0x77, 5], b[9] >> 6 == 1,
          b[10] == 0x10, b[124] == 0,
          Int(b[9] & 63) == b[10..<125].reduce(0, { $0 + Int($1) }) & 63 else { return nil }
    return Data(b[13..<124])
}

public struct Mini2SPPStatus {
    public let bytes: [UInt8]
    public var batteryLevel: Mini2BatteryLevel? { Mini2BatteryLevel(rawValue: bytes[13]) }
    public var capture: UInt8 { bytes[12] }
    public var denoise: Bool { bytes[11] & 0x80 != 0 }
    public var denoiseButtonDisabled: Bool { bytes[15] & 0x08 != 0 }
    public var denoiseLevel: UInt8 { (bytes[15] >> 5) & 3 }
}

/// Firmware serializes one status byte per wireless block, including capability blocks.
/// Snapshot events are counted per complete frame, not deduplicated by payload equality.
public struct Mini2StatusParser {
    private var buffer: [UInt8] = []
    private var lastSequence: UInt8?
    private var lastAudio: Data?
    public private(set) var sequenceGaps = 0
    public private(set) var invalidBlocks = 0
    public private(set) var duplicateBlocks = 0
    public init() {}
    public mutating func resetFraming() { buffer.removeAll(); lastSequence = nil; lastAudio = nil }
    public mutating func feed(_ block: Data) -> [Mini2SPPStatus] {
        let b = [UInt8](block)
        guard b.count == 125, Array(b[6..<9]) == [0x55, 0x77, 5], b[9] >> 6 == 1,
              [UInt8(0x10), 0x20].contains(b[10]),
              Int(b[9] & 63) == b[10..<125].reduce(0, { $0 + Int($1) }) & 63 else {
            invalidBlocks += 1; resetFraming(); return []
        }
        if b[10] == 0x10 {
            if lastAudio == block { duplicateBlocks += 1; return [] }
            if let lastSequence, b[12] != lastSequence &+ 1 { sequenceGaps += 1; buffer.removeAll() }
            lastSequence = b[12]; lastAudio = block
        }
        buffer.append(b[11])
        var result: [Mini2SPPStatus] = []
        while buffer.count >= 22 {
            let p = Array(buffer.prefix(22))
            if Array(p[0..<3]) == [0x55, 0x16, 5], p[3] >> 6 == 0,
               Array(p[4..<8]) == [0x19, 0, 0, 1],
               Int(p[3] & 63) == p[4..<22].reduce(0, { $0 + Int($1) }) & 63,
               crc8(Array(p[10..<22])) == p[9] {
                result.append(Mini2SPPStatus(bytes: p)); buffer.removeFirst(22)
            } else { buffer.removeFirst() }
        }
        return result
    }
}

/// Wireless 19/11 control, not DUML. Layout follows the receiver firmware.
public func mini2DenoisePacket(enabled: Bool) -> [UInt8] {
    var frame: [UInt8] = [0x55, 9, 0x58, 0, 0x19, 0, 0, 0x11, enabled ? 1 : 0]
    frame[3] = UInt8(frame[4...].reduce(0) { $0 + Int($1) } & 63)
    return [0xaa, 4, 0] + frame + [UInt8](repeating: 0, count: 125 - frame.count) + [0xa5]
}

/// Require fresh, stable status after the write; a write return is not an ACK.
public struct Mini2DenoiseConfirmation {
    public let target: Bool
    private let sentAt: TimeInterval
    private var consecutive = 0
    public init(target: Bool, sentAt: TimeInterval) { self.target = target; self.sentAt = sentAt }
    public func expired(at time: TimeInterval) -> Bool { time >= sentAt + 6 }
    public mutating func observe(_ value: Bool, at time: TimeInterval) -> Bool {
        guard time >= sentAt + 0.3, !expired(at: time) else { return false }
        consecutive = value == target ? consecutive + 1 : 0
        return consecutive >= 3
    }
}
