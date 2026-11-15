import XCTest
@testable import Mini2Protocol
final class ToolHandshakeTests: XCTestCase {
    func testHeaderMatchesStockFirmwareOffsets() {
        let bytes = Mini2ToolHandshake.request(sequence: 0x5a)
        XCTAssertEqual(bytes.count, 12)
        XCTAssertEqual(bytes[0], 0x90)
        XCTAssertEqual(UInt16(bytes[2]) | UInt16(bytes[3]) << 8, 0x7063)
        let magic = bytes[8..<12].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        XCTAssertEqual(magic, 0x7063 + 0x1f000000 + 0x176000 + 0x3d9)
        XCTAssertEqual(Array(bytes[4..<8]), [0,0,0,0])
    }
    func testOnlyExactSuccessfulReplyIsAccepted() {
        XCTAssertTrue(Mini2ToolHandshake.acknowledged([0xaa,0x5a,0,0], sequence: 0x5a))
        for bytes: [UInt8] in [[0xaa,0x5b,0,0], [0xaa,0x5a,0,5], [0xaa,0x5a,0], [0xaa,0x5a,0,0,0]] {
            XCTAssertFalse(Mini2ToolHandshake.acknowledged(bytes, sequence: 0x5a))
        }
    }
}
