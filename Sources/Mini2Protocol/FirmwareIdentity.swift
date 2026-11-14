import Foundation

/// A version read from this transmitter over BLE, retained across SPP sessions.
public struct Mini2FirmwareIdentity: Codable, Equatable {
    public let version: String
    public let readAt: Date
    public let peripheralID: UUID

    public init?(payload: [UInt8], peripheralID: UUID, readAt: Date = Date()) {
        guard payload.count == 30, payload[0] == 0,
              Mini2Request.product(payload) == "DJI MIC MINI TX",
              payload[22..<26].contains(where: { $0 != 0 }),
              let version = Mini2Request.version(payload) else { return nil }
        self.version = version; self.readAt = readAt; self.peripheralID = peripheralID
    }

    public static func addressKey(_ address: String) -> String? {
        let key = address.uppercased().filter { $0.isHexDigit }
        return key.count == 12 ? key : nil
    }

    /// Match the specific paired transmitter's address suffix, never the first Mini nearby.
    public static func matches(advertisedName: String, address: String) -> Bool {
        guard let address = addressKey(address) else { return false }
        let name = advertisedName.uppercased().filter { $0.isLetter || $0.isNumber }
        return name == "DJIMICMINI2" + address.suffix(6)
    }
}
