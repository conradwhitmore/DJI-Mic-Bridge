import Foundation

/// Only the non-configuring ABTP handshake. No gain, calibration, AT or OTA commands.
public enum Mini2ToolHandshake {
    public static func request(sequence: UInt8) -> [UInt8] {
        [0x90, sequence, 0x63, 0x70, 0, 0, 0, 0, 0x3c, 0xd4, 0x17, 0x1f]
    }
    public static func acknowledged(_ bytes: [UInt8], sequence: UInt8) -> Bool {
        bytes == [0xaa, sequence, 0, 0]
    }
}
