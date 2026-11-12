import Foundation

/// Independent factory key reports, separate from 02/FF state correlations.
/// TX 04.05.01.11 0x102c12c: 04/68, payload 43 01 {1,2,3}.
public struct MicKeyTestEvent {
    public let button: MicButton
    public let sequence: UInt16
    public init?(frame c: [UInt8]) {
        guard c.count == 16, c[0] == 0x55, c[1] == 16, c[2] == 4,
              c[4] == 0x3a, c[5] == 2, c[8] == 0, c[9] == 4, c[10] == 0x68,
              c[11] == 0x43, c[12] == 1,
              crc8(Array(c.prefix(3))) == c[3],
              crc16(Array(c.dropLast(2))) == UInt16(c[14]) | UInt16(c[15]) << 8 else { return nil }
        switch c[13] {
        case 1: button = .power
        case 2: button = .record
        case 3: button = .link
        default: return nil
        }
        sequence = UInt16(c[6]) | UInt16(c[7]) << 8
    }
}
