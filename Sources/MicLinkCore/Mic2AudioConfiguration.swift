import Foundation

/// Mic 2 02/A0 snapshot, matched to the 04.05.01.11 TX handler and
/// 04.05.02.31 live replies. Read status bits are not write action bits.
public struct Mic2AudioConfiguration {
    private let bytes: [UInt8]
    public init(reply: [UInt8]) throws {
        guard reply.count == 28, reply[0] == 0,
              reply[1..<18].allSatisfy({ $0 == 0 }),
              reply[21] == 0, reply[22] == 0,
              Array(reply[18..<23]) == Array(reply[23..<28]),
              reply[19] & 0x0f == 0, reply[20] <= 24,
              [UInt8(0), 8].contains(reply[18] & 0x0c) else {
            throw StreamError.invalid("TX 配置结构不匹配，未写入")
        }
        bytes = reply
    }
    public var vibrationEnabled: Bool { bytes[18] & 0x10 != 0 }
    public func vibrationWritePayload(enabled: Bool) throws -> [UInt8] {
        // Bit 0 writes START/STOP recording. Do not issue settings writes while
        // the transmitter is recording, even if the caller would echo that bit.
        guard bytes[18] & 1 == 0 else { throw StreamError.invalid("请先停止发射器本地录音，未写入") }
        var result = [UInt8](repeating: 0, count: 27)
        result[17] = (bytes[18] & ~0x10) | (enabled ? 0x10 : 0)
        // Only denoise/HDR are settings here. Bit 6 of the write is FORMAT;
        // the read returns a live status at that position. Never echo it.
        result[18] = bytes[19] & 0x30
        result[19] = bytes[20]
        // The getter mirrors the TX block into the second slot.
        for i in 0..<5 { result[22 + i] = result[17 + i] }
        return result
    }
    public var denoiseEnabled: Bool { bytes[19] & 0x10 != 0 }
    public func denoiseWritePayload(enabled: Bool) throws -> [UInt8] {
        // Reuse the reviewed settings encoding, including clearing FORMAT/action bits.
        var result = try vibrationWritePayload(enabled: vibrationEnabled)
        result[18] = (result[18] & ~0x10) | (enabled ? 0x10 : 0)
        result[23] = result[18]
        return result
    }
    public func matches(_ original: Self, denoiseEnabled: Bool) -> Bool {
        let expected = (original.bytes[19] & 0x20) | (denoiseEnabled ? 0x10 : 0)
        return bytes[18] == original.bytes[18] && bytes[19] & 0x30 == expected
            && bytes[20] == original.bytes[20]
    }
    public func matches(_ original: Self, vibrationEnabled: Bool) -> Bool {
        let expectedFlags = (original.bytes[18] & ~0x10) | (vibrationEnabled ? 0x10 : 0)
        return bytes[18] == expectedFlags && bytes[19] & 0x30 == original.bytes[19] & 0x30
            && bytes[20] == original.bytes[20]
    }
}
