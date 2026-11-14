import XCTest
import Mini2Protocol

final class FirmwareIdentityTests: XCTestCase {
    func testDiscoveryMatchesOnlySelectedMini2AddressSuffix() {
        XCTAssertTrue(Mini2FirmwareIdentity.matches(advertisedName: "DJI Mic Mini 2-445566", address: "11-22-33-44-55-66"))
        XCTAssertTrue(Mini2FirmwareIdentity.matches(advertisedName: "DJI Mic Mini 2-445566", address: "11:22:33:44:55:66"))
        XCTAssertFalse(Mini2FirmwareIdentity.matches(advertisedName: "DJI Mic Mini 2-112233", address: "11:22:33:44:55:66"))
        XCTAssertFalse(Mini2FirmwareIdentity.matches(advertisedName: "DJI Mic Mini-445566", address: "11:22:33:44:55:66"))
        XCTAssertFalse(Mini2FirmwareIdentity.matches(advertisedName: "DJI Mic Mini 2S-445566", address: "11:22:33:44:55:66"))
        XCTAssertFalse(Mini2FirmwareIdentity.matches(advertisedName: "DJI Mic Mini 2-445566", address: "445566"))
        XCTAssertEqual(Mini2FirmwareIdentity.addressKey("11-22-33-44-55-66"), Mini2FirmwareIdentity.addressKey("11:22:33:44:55:66"))
    }

    func testCachePreservesActualVersionAndRejectsInvalidReplies() throws {
        var payload = [UInt8](repeating: 0, count: 30)
        payload.replaceSubrange(2..<18, with: Array("DJI MIC MINI TX".utf8) + [0])
        payload.replaceSubrange(22..<26, with: [0, 17, 3, 2])
        let id = UUID(), date = Date(timeIntervalSince1970: 1234)
        let identity = try XCTUnwrap(Mini2FirmwareIdentity(payload: payload, peripheralID: id, readAt: date))
        XCTAssertEqual(identity.version, "02.03.17.00")
        let decoded = try JSONDecoder().decode(Mini2FirmwareIdentity.self, from: JSONEncoder().encode(identity))
        XCTAssertEqual(decoded, identity)
        payload[23] = 18
        XCTAssertEqual(Mini2FirmwareIdentity(payload: payload, peripheralID: id)?.version, "02.03.18.00")
        payload[0] = 1
        XCTAssertNil(Mini2FirmwareIdentity(payload: payload, peripheralID: id))
        payload[0] = 0; payload[2] = 0
        XCTAssertNil(Mini2FirmwareIdentity(payload: payload, peripheralID: id))
        XCTAssertNil(Mini2FirmwareIdentity(payload: [], peripheralID: id))
        XCTAssertNil(Mini2FirmwareIdentity(payload: [UInt8](repeating: 0, count: 30), peripheralID: id))
    }
}
